/* A C library for the by-value FFI fixture (M2.13, D-096): structs and unions that the
   C calling conventions pass in different ways, in registers or in memory. */
#include <stdint.h>

#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif

typedef struct { float x, y; } vec2f;               /* two floats: FP registers */
typedef struct { double x, y, w, h; } rectd;        /* 32 bytes: memory on x86-64 */
typedef struct { int32_t a; int64_t b; uint8_t c; } mixed;  /* 24 bytes, padded */
typedef struct { uint8_t r, g, b, a; } color;       /* 4 bytes: one integer register */
typedef struct { vec2f origin; vec2f size; } frame; /* nested */
typedef union { int32_t i; float f; } num;
typedef struct { int32_t v[3]; } triple;

EXPORT vec2f vec2_add(vec2f a, vec2f b) { vec2f r = {a.x + b.x, a.y + b.y}; return r; }
EXPORT float vec2_dot(vec2f a, vec2f b) { return a.x * b.x + a.y * b.y; }
EXPORT rectd rect_grow(rectd r, double by) {
  rectd g = {r.x - by, r.y - by, r.w + 2 * by, r.h + 2 * by};
  return g;
}
EXPORT int64_t mixed_sum(mixed m) { return m.a + m.b + m.c; }
EXPORT mixed mixed_make(int32_t a, int64_t b, uint8_t c) { mixed m = {a, b, c}; return m; }
EXPORT color color_invert(color c) {
  color r = {(uint8_t)(255 - c.r), (uint8_t)(255 - c.g), (uint8_t)(255 - c.b), c.a};
  return r;
}
EXPORT frame frame_offset(frame f, float dx) { f.origin.x += dx; return f; }
EXPORT float num_as_float(num n) { return n.f; }
EXPORT num num_from_int(int32_t i) { num n; n.i = i; return n; }
EXPORT int32_t triple_sum(triple t) { return t.v[0] + t.v[1] + t.v[2]; }

/* Callbacks that take and return structs by value (step 2). */
typedef vec2f (*vec2_fn)(vec2f v, float k);
typedef rectd (*rect_fn)(rectd r);
typedef int64_t (*mixed_fn)(mixed m);
typedef color (*color_fn)(color c);
EXPORT vec2f apply_vec2(vec2_fn f, vec2f v) { return f(v, 2.0f); }
EXPORT rectd apply_rect(rect_fn f) { rectd r = {1.0, 2.0, 3.0, 4.0}; return f(r); }
EXPORT int64_t apply_mixed(mixed_fn f) { mixed m = {7, 40000000000, 9}; return f(m) + 1; }
EXPORT color apply_color(color_fn f, color c) { return f(c); }

/* Calls through function pointers (step 3): a table of them, as COM's vtables are, and
   one that takes structs by value. And one symbol bound under two signatures. */
typedef int64_t (*binop)(int64_t a, int64_t b);
static int64_t op_add(int64_t a, int64_t b) { return a + b; }
static int64_t op_mul(int64_t a, int64_t b) { return a * b; }
typedef struct { binop ops[2]; } op_table;
EXPORT const op_table *ops_table(void) { static const op_table t = {{op_add, op_mul}}; return &t; }
typedef vec2f (*vec2_op)(vec2f a, vec2f b);
EXPORT vec2_op vec2_add_pointer(void) { return vec2_add; }
EXPORT uint64_t length_of(const char *s) { uint64_t n = 0; while (s[n]) n++; return n; }
