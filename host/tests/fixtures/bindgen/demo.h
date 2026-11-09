/* A small header for the bindgen golden test. */
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#define DEMO_VERSION 3
#define DEMO_FLAG_A 0x01u
#define DEMO_FLAG_B (1u << 4)
#define DEMO_FLAGS_AB (DEMO_FLAG_A | DEMO_FLAG_B)
#define DEMO_BIG DEMO_UINT64_C(0x8000000000000000)
#define DEMO_UINT64_C(c) c##ULL
#define DEMO_SCALE 1.5f
#define DEMO_NAME "demo"
#define DEMO_NEG (-2)
#define DEMO_CAST ((uint32_t)7)

typedef uint32_t DEMO_Flags;
typedef struct DEMO_Window DEMO_Window;

typedef struct DEMO_FPoint { float x; float y; } DEMO_FPoint;

typedef struct DEMO_Rect {
  int x, y;
  int w, h;
} DEMO_Rect;

typedef enum DEMO_Color {
  DEMO_COLOR_RED,
  DEMO_COLOR_GREEN = 5,
  DEMO_COLOR_BLUE,
  DEMO_COLOR_DARK_GRAY = -1
} DEMO_Color;

typedef struct DEMO_KeyEvent {
  uint32_t type;
  uint64_t timestamp;
  DEMO_Window *window;
  bool down;
  char text[8];
} DEMO_KeyEvent;

typedef union DEMO_Event {
  uint32_t type;
  DEMO_KeyEvent key;
  uint8_t padding[64];
} DEMO_Event;

typedef struct { int a; float b; } DEMO_Anon;

typedef struct DEMO_Binding {
  int kind;
  union {
    int button;
    struct { int axis; int direction; } hat;
  } input;
} DEMO_Binding;

typedef void (*DEMO_LogFunc)(void *userdata, int category, const char *message);

extern bool DEMO_Init(DEMO_Flags flags);
extern void DEMO_Quit(void);
extern const char *DEMO_GetError(void);
extern DEMO_Window *DEMO_CreateWindow(const char *title, int w, int h, uint64_t flags);
extern bool DEMO_GetWindowSize(DEMO_Window *window, int *w, int *h);
extern bool DEMO_PollEvent(DEMO_Event *event);
extern void DEMO_SetColor(DEMO_Color color);
extern void DEMO_SetLogFunc(DEMO_LogFunc callback, void *userdata);
extern size_t DEMO_GetGPUDeviceCount(void);
extern double DEMO_Mix(float a, double b, int8_t c, unsigned long d);
extern DEMO_FPoint DEMO_GetCenter(const DEMO_Rect *rect);
extern int DEMO_Log(const char *fmt, ...);
static inline int DEMO_Twice(int x) { return x * 2; }
extern void *DEMO_Malloc(size_t size);
int other_function(void);
