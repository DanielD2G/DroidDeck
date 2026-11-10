import json
import os
from pathlib import Path
import runpy
import tempfile
import unittest


BIN = Path(__file__).resolve().parents[1] / 'linuxfs/overlay/usr/local/bin'
MODULE = runpy.run_path(str(BIN / 'droiddeck-game-cores'))
Placer = MODULE['Placer']
Governor = MODULE['Governor']
POLL = MODULE['POLL']
RETRY_AFTER = MODULE['RETRY_AFTER']

EVERY = set(range(8))
FAST = {6, 7}
HZ = 100


class FakeCores:

    def __init__(self):
        self.state = {}
        self.calls = []

    def get(self, tid):
        if tid not in self.state:
            raise ProcessLookupError(tid)
        return set(self.state[tid])

    def set(self, tid, cpus):
        if tid not in self.state:
            raise ProcessLookupError(tid)
        self.calls.append((tid, set(cpus)))
        self.state[tid] = set(cpus)


class GameCoresTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.proc = self.root / 'proc'
        self.proc.mkdir()
        self.cpufreq = self.root / 'cpu'
        for cpu in EVERY:
            (self.cpufreq / f'cpu{cpu}/cpufreq').mkdir(parents=True)
            top = '4608000\n' if cpu in FAST else '3628800\n'
            (self.cpufreq / f'cpu{cpu}/cpufreq/cpuinfo_max_freq').write_text(top)
            (self.cpufreq / f'cpu{cpu}/cpufreq/scaling_max_freq').write_text('4608000\n' if cpu in FAST else '2496000\n')
        self.cores = FakeCores()
        self.now = 0.0
        self.used = {}
        self.placer = Placer(self.proc, self.cpufreq, self.cores, clock=lambda: self.now, hz=HZ)
        self.focus = self.root / 'focus.json'
        self.governor = Governor(self.focus, self.placer)

    def process(self, pid, threads=(), name='game.exe', prefix='/pfx', cpus=EVERY):
        directory = self.proc / str(pid)
        (directory / 'task').mkdir(parents=True)
        (directory / 'comm').write_text(name + '\n')
        (directory / 'environ').write_bytes(b'A=1\0WINEPREFIX=' + prefix.encode() + b'\0')
        for tid in (pid, *threads):
            (directory / 'task' / str(tid)).mkdir()
            self.cores.state[tid] = set(cpus)
            self.run_thread(pid, tid, 0.0, 0)

    def run_thread(self, pid, tid, seconds, cpu):
        self.used[tid] = self.used.get(tid, 0) + round(seconds * HZ)
        fields = ['S'] + ['0'] * 10 + [str(self.used[tid]), '0'] + ['0'] * 23 + [str(cpu)]
        (self.proc / str(pid) / 'task' / str(tid) / 'stat').write_text(f'{tid} (a b) ' + ' '.join(fields) + '\n')

    def focus_on(self, pid, app=4231820):
        stamp = getattr(self, 'stamp', 1_000_000_000) + 1_000_000_000
        self.stamp = stamp
        self.focus.write_text(json.dumps({
            'focusedApp': app, 'focusedWindow': 2,
            'focusableWindows': [{'window': 1, 'appId': 769, 'pid': 9}, {'window': 2, 'appId': app, 'pid': pid}]}))
        os.utime(self.focus, ns=(stamp, stamp))

    def step(self, load):
        self.now += POLL
        for (pid, tid), (share, cpu) in load.items():
            self.run_thread(pid, tid, share * POLL, cpu)
        self.governor.tick()

    def test_a_game_that_fits_moves_whole_onto_the_fast_cores_with_its_wineserver(self):
        self.process(100, (101, 102))
        self.process(50, name='wineserver')
        self.process(60, name='wineserver', prefix='/other')
        self.focus_on(100)
        self.governor.tick()
        self.assertEqual([], self.cores.calls)
        self.step({(100, 100): (0.7, 6), (100, 101): (0.4, 2), (100, 102): (0.7, 3), (50, 50): (0.02, 4)})
        for tid in (100, 101, 102, 50):
            self.assertEqual(FAST, self.cores.state[tid], tid)
        self.assertEqual(EVERY, self.cores.state[60])

    def test_work_on_capped_cores_counts_for_less_than_work_on_the_fast_ones(self):
        self.process(100, (101, 102, 103))
        self.focus_on(100)
        self.governor.tick()
        self.step({(100, 100): (0.7, 6), (100, 101): (0.6, 2), (100, 102): (0.6, 3), (100, 103): (0.5, 4)})
        self.assertEqual(FAST, self.cores.state[103])

    def test_a_heavy_game_keeps_every_core_and_only_its_busiest_threads_go_fast(self):
        self.process(100, (101, 102, 103, 104))
        self.focus_on(100)
        self.governor.tick()
        load = {(100, 100): (0.9, 6), (100, 101): (0.8, 7), (100, 102): (0.7, 2), (100, 103): (0.7, 3), (100, 104): (0.05, 4)}
        self.step(load)
        self.assertEqual(FAST, self.cores.state[100])
        self.assertEqual(FAST, self.cores.state[101])
        for tid in (102, 103, 104):
            self.assertEqual(EVERY, self.cores.state[tid], tid)

    def test_a_game_that_fills_the_fast_cores_gets_the_others_back_and_is_not_retried_at_once(self):
        self.process(100, (101,))
        self.focus_on(100)
        self.governor.tick()
        light = {(100, 100): (0.6, 6), (100, 101): (0.3, 7)}
        self.step(light)
        self.assertEqual(FAST, self.cores.state[101])
        full = {(100, 100): (0.98, 6), (100, 101): (0.95, 7)}
        self.step(full)
        self.assertEqual(FAST, self.cores.state[101])
        self.step(full)
        self.assertEqual(FAST, self.cores.state[100])
        self.step({(100, 100): (0.6, 6), (100, 101): (0.05, 2)})
        self.assertEqual(EVERY, self.cores.state[101])
        self.now += RETRY_AFTER
        self.step({(100, 100): (0.6, 6), (100, 101): (0.05, 2)})
        self.step({(100, 100): (0.6, 6), (100, 101): (0.05, 2)})
        self.assertEqual(FAST, self.cores.state[101])
        self.step(full)
        self.step(full)
        self.step(light)
        self.now += RETRY_AFTER
        self.step(light)
        self.assertEqual(EVERY, self.cores.state[101])
        self.now += RETRY_AFTER
        self.step(light)
        self.step(light)
        self.assertEqual(FAST, self.cores.state[101])

    def test_focus_back_on_steam_returns_every_thread_to_the_cores_it_had(self):
        self.process(100, (101,), cpus={2, 3, 4, 5, 6, 7})
        self.process(50, name='wineserver', cpus={2, 3, 4, 5, 6, 7})
        self.focus_on(100)
        self.governor.tick()
        self.step({(100, 100): (0.5, 6), (100, 101): (0.2, 2)})
        self.assertEqual(FAST, self.cores.state[50])
        self.focus_on(9, app=769)
        self.governor.tick()
        for tid in (100, 101, 50):
            self.assertEqual({2, 3, 4, 5, 6, 7}, self.cores.state[tid], tid)

    def test_the_steam_overlay_over_a_running_game_keeps_the_game_placed(self):
        self.process(100, (101,))
        self.focus_on(100)
        self.governor.tick()
        self.step({(100, 100): (0.5, 6), (100, 101): (0.2, 2)})
        snapshot = json.loads(self.focus.read_text())
        snapshot['focusedApp'] = 769
        self.focus.write_text(json.dumps(snapshot))
        os.utime(self.focus, ns=(self.stamp + 5, self.stamp + 5))
        self.step({(100, 100): (0.5, 6), (100, 101): (0.2, 6)})
        self.assertEqual(FAST, self.cores.state[101])

    def test_cores_the_user_picked_are_never_widened(self):
        self.process(100, (101,), cpus={0, 1, 2})
        self.focus_on(100)
        self.governor.tick()
        self.step({(100, 100): (0.5, 0), (100, 101): (0.2, 1)})
        self.assertEqual([], self.cores.calls)

    def test_a_game_that_exits_is_forgotten(self):
        self.process(100, (101,))
        self.focus_on(100)
        self.governor.tick()
        self.step({(100, 100): (0.5, 6), (100, 101): (0.2, 2)})
        for tid in ('100', '101'):
            (self.proc / '100/task' / tid / 'stat').unlink()
            (self.proc / '100/task' / tid).rmdir()
            self.cores.state.pop(int(tid))
        self.now += POLL
        self.governor.tick()
        self.governor.tick()
        self.assertIsNone(self.placer.mode)


if __name__ == '__main__':
    unittest.main()
