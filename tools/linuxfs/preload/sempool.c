#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <unistd.h>

/* Some Unity games create and close an unused unnamed semaphore thousands of times a second, each
 * a wineserver round trip. A semaphore no request named between its create and its close stays
 * open and answers the next identical create. BL_SEMPOOL holds "<create_semaphore>,<close_handle>". */

int bl_from_ntdll(const void *caller) __attribute__((visibility("hidden")));

#define SP_MSG 64
#define SP_HDR 12
#define SP_OBJATTR 16
#define SP_FREE 16
#define SP_LIVE 64

struct sp_key {
  uint32_t access, initial, max, attributes;
};

struct sp_entry {
  uint32_t handle;
  int dirty;
  struct sp_key key;
};

static int sp_state = -1;
static int sp_create_req, sp_close_req;
static pthread_mutex_t sp_lock = PTHREAD_MUTEX_INITIALIZER;
static struct sp_entry sp_live[SP_LIVE];
static int sp_nlive;
static struct sp_entry sp_free[SP_FREE];
static int sp_nfree;
static int sp_tracked;

enum { SP_IDLE, SP_CAPTURE, SP_FAKE };
static __thread int sp_pending;
static __thread unsigned char sp_reply[SP_MSG];
static __thread struct sp_key sp_capture;

static ssize_t (*sp_real_read)(int, void *, size_t);
static ssize_t (*sp_real_write)(int, const void *, size_t);
static ssize_t (*sp_real_writev)(int, const struct iovec *, int);

static int sp_on(void) {
  int s = __atomic_load_n(&sp_state, __ATOMIC_ACQUIRE);
  if (s >= 0) return s;
  const char *e = getenv("BL_SEMPOOL");
  char *end = NULL;
  long create = e ? strtol(e, &end, 10) : -1, close = -1;
  if (create >= 0 && end && *end == ',') close = strtol(end + 1, &end, 10);
  s = create >= 0 && create < 4096 && close >= 0 && close < 4096 && create != close && *end == 0;
  if (s) {
    sp_create_req = (int)create;
    sp_close_req = (int)close;
  }
  __atomic_store_n(&sp_state, s, __ATOMIC_RELEASE);
  return s;
}

static uint32_t sp_u32(const void *p) {
  uint32_t v;
  memcpy(&v, p, sizeof v);
  return v;
}

static void sp_fake(uint32_t error, uint32_t handle) {
  memset(sp_reply, 0, sizeof sp_reply);
  memcpy(sp_reply, &error, sizeof error);
  memcpy(sp_reply + 8, &handle, sizeof handle);
  sp_pending = SP_FAKE;
}

static void sp_count(void) {
  __atomic_store_n(&sp_tracked, sp_nlive + sp_nfree, __ATOMIC_RELEASE);
}

static void sp_drop_free(int i) {
  sp_free[i] = sp_free[--sp_nfree];
}

static void sp_drop_live(int i) {
  sp_live[i] = sp_live[--sp_nlive];
}

static void sp_mark(const unsigned char *p, size_t n, uint32_t except) {
  for (size_t off = 0; off + 4 <= n; off += 4) {
    uint32_t v = sp_u32(p + off);
    if (!v || v == except) continue;
    for (int i = 0; i < sp_nlive; i++)
      if (sp_live[i].handle == v) sp_live[i].dirty = 1;
    for (int i = sp_nfree - 1; i >= 0; i--)
      if (sp_free[i].handle == v) sp_drop_free(i);
  }
}

static void sp_scan(const struct iovec *iov, int n, uint32_t except) {
  if (!__atomic_load_n(&sp_tracked, __ATOMIC_ACQUIRE)) return;
  pthread_mutex_lock(&sp_lock);
  sp_mark((const unsigned char *)iov[0].iov_base + SP_HDR, SP_MSG - SP_HDR, except);
  for (int i = 1; i < n; i++) sp_mark(iov[i].iov_base, iov[i].iov_len, except);
  sp_count();
  pthread_mutex_unlock(&sp_lock);
}

static void sp_track(uint32_t handle, const struct sp_key *key) {
  pthread_mutex_lock(&sp_lock);
  if (sp_nlive == SP_LIVE) {
    int victim = 0;
    for (int i = 0; i < sp_nlive; i++)
      if (sp_live[i].dirty) { victim = i; break; }
    sp_drop_live(victim);
  }
  sp_live[sp_nlive++] = (struct sp_entry){ handle, 0, *key };
  sp_count();
  pthread_mutex_unlock(&sp_lock);
}

static int sp_reuse(const struct sp_key *key, uint32_t *handle) {
  int found = 0;
  pthread_mutex_lock(&sp_lock);
  for (int i = 0; i < sp_nfree && sp_nlive < SP_LIVE; i++) {
    if (memcmp(&sp_free[i].key, key, sizeof *key)) continue;
    *handle = sp_free[i].handle;
    sp_live[sp_nlive++] = (struct sp_entry){ *handle, 0, *key };
    sp_drop_free(i);
    found = 1;
    break;
  }
  sp_count();
  pthread_mutex_unlock(&sp_lock);
  return found;
}

static int sp_keep(uint32_t handle) {
  int kept = 0;
  pthread_mutex_lock(&sp_lock);
  for (int i = 0; i < sp_nlive; i++) {
    if (sp_live[i].handle != handle) continue;
    if (!sp_live[i].dirty && sp_nfree < SP_FREE) {
      sp_free[sp_nfree++] = sp_live[i];
      kept = 1;
    }
    sp_drop_live(i);
    break;
  }
  sp_count();
  pthread_mutex_unlock(&sp_lock);
  return kept;
}

static int sp_create_key(const struct iovec *iov, int n, struct sp_key *key) {
  const unsigned char *req = iov[0].iov_base;
  if (n != 2 || iov[1].iov_len != SP_OBJATTR || sp_u32(req + 4) != SP_OBJATTR) return 0;
  const unsigned char *attr = iov[1].iov_base;
  if (sp_u32(attr) || sp_u32(attr + 8) || sp_u32(attr + 12)) return 0;
  *key = (struct sp_key){ sp_u32(req + 12), sp_u32(req + 16), sp_u32(req + 20), sp_u32(attr + 4) };
  return 1;
}

static ssize_t sp_send(const struct iovec *iov, int n) {
  const unsigned char *req = iov[0].iov_base;
  int code = (int)sp_u32(req);
  if (code == sp_close_req && n == 1) {
    uint32_t handle = sp_u32(req + SP_HDR);
    if (sp_keep(handle)) {
      sp_fake(0, 0);
      return SP_MSG;
    }
    sp_scan(iov, n, handle);
    return -2;
  }
  sp_scan(iov, n, 0);
  struct sp_key key;
  if (code == sp_create_req && sp_create_key(iov, n, &key)) {
    uint32_t handle;
    if (sp_reuse(&key, &handle)) {
      sp_fake(0, handle);
      return SP_MSG + SP_OBJATTR;
    }
    sp_capture = key;
    sp_pending = SP_CAPTURE;
  }
  return -2;
}

static void sp_resolve(void) {
  if (!sp_real_read) sp_real_read = (ssize_t (*)(int, void *, size_t))dlsym(RTLD_NEXT, "read");
  if (!sp_real_write) sp_real_write = (ssize_t (*)(int, const void *, size_t))dlsym(RTLD_NEXT, "write");
  if (!sp_real_writev) sp_real_writev = (ssize_t (*)(int, const struct iovec *, int))dlsym(RTLD_NEXT, "writev");
}

ssize_t write(int fd, const void *buf, size_t count) {
  if (__builtin_expect(!sp_real_write, 0)) sp_resolve();
  if (count == SP_MSG && sp_on() && bl_from_ntdll(__builtin_return_address(0))) {
    struct iovec one = { (void *)buf, count };
    ssize_t r = sp_send(&one, 1);
    if (r != -2) return r;
  }
  return sp_real_write(fd, buf, count);
}

ssize_t writev(int fd, const struct iovec *iov, int iovcnt) {
  if (__builtin_expect(!sp_real_writev, 0)) sp_resolve();
  if (iovcnt > 0 && iov[0].iov_len == SP_MSG && sp_on() && bl_from_ntdll(__builtin_return_address(0))) {
    ssize_t r = sp_send(iov, iovcnt);
    if (r != -2) return r;
    size_t total = 0;
    for (int i = 0; i < iovcnt; i++) total += iov[i].iov_len;
    r = sp_real_writev(fd, iov, iovcnt);
    if (r != (ssize_t)total) sp_pending = SP_IDLE;
    return r;
  }
  return sp_real_writev(fd, iov, iovcnt);
}

ssize_t read(int fd, void *buf, size_t count) {
  if (__builtin_expect(!sp_real_read, 0)) sp_resolve();
  if (__builtin_expect(sp_pending != SP_IDLE, 0) && count == SP_MSG) {
    if (sp_pending == SP_FAKE) {
      sp_pending = SP_IDLE;
      memcpy(buf, sp_reply, SP_MSG);
      return SP_MSG;
    }
    sp_pending = SP_IDLE;
    struct sp_key key = sp_capture;
    ssize_t r = sp_real_read(fd, buf, count);
    if (r == SP_MSG && !sp_u32(buf) && !sp_u32((unsigned char *)buf + 4) && sp_u32((unsigned char *)buf + 8))
      sp_track(sp_u32((unsigned char *)buf + 8), &key);
    return r;
  }
  return sp_real_read(fd, buf, count);
}
