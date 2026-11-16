// A small C bridge over ONNX Runtime's C API, for Android, where the Objective-C bindings ScannerCore uses on Apple
// platforms don't build. libonnxruntime.so is loaded at run time (the app packages it, from Microsoft's
// onnxruntime-android), so this package needs no linker flags. Only what ScannerCore calls is here.
//
// Every function that can fail returns NULL or a negative number and writes a message into `err`.

#ifndef SC_ORT_H
#define SC_ORT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sc_ort_session sc_ort_session;
typedef struct sc_ort_value sc_ort_value;

enum { SC_ORT_FLOAT = 1, SC_ORT_INT64 = 7 };  // ONNX tensor element types

/// Loads libonnxruntime.so and creates the process's one environment. Safe to call repeatedly.
int sc_ort_load(char *err, size_t errlen);

sc_ort_session *sc_ort_session_create(const char *model_path, int intra_op_threads, const char *const *config_keys,
                                      const char *const *config_values, size_t config_count, char *err, size_t errlen);
void sc_ort_session_free(sc_ort_session *session);

/// Input (`output` 0) or output (`output` 1) names. Returns the count; the caller frees each name with free().
long sc_ort_session_names(sc_ort_session *session, int output, char ***names, char *err, size_t errlen);

/// A tensor holding a copy of `bytes` bytes of `data`.
sc_ort_value *sc_ort_value_create(const void *data, size_t bytes, int element_type, const int64_t *shape, size_t rank,
                                  char *err, size_t errlen);
void sc_ort_value_free(sc_ort_value *value);

/// Runs the session; `outputs` receives `output_count` new values.
int sc_ort_session_run(sc_ort_session *session, const char *const *input_names, sc_ort_value *const *inputs,
                       size_t input_count, const char *const *output_names, size_t output_count,
                       sc_ort_value **outputs, char *err, size_t errlen);

/// The tensor's data (owned by the value) and its size in bytes.
const void *sc_ort_value_data(sc_ort_value *value, size_t *bytes, char *err, size_t errlen);
/// The tensor's shape: returns the rank, writing up to `max_rank` dimensions.
long sc_ort_value_shape(sc_ort_value *value, int64_t *shape, size_t max_rank, char *err, size_t errlen);
int sc_ort_value_element_type(sc_ort_value *value);

#ifdef __cplusplus
}
#endif

#endif
