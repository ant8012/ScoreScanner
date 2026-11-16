// See include/sc_ort.h.

#include "sc_ort.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ort/onnxruntime_c_api.h"

struct sc_ort_session { OrtSession *session; };
struct sc_ort_value { OrtValue *value; };

static const OrtApi *api;
static OrtEnv *env;
static char load_error[256];
static pthread_once_t load_once = PTHREAD_ONCE_INIT;

static void set_err(char *err, size_t errlen, const char *message) {
  if (err && errlen) snprintf(err, errlen, "%s", message);
}

/// Copies a failed status's message into `err` and releases it. Returns 0 on success, -1 on failure.
static int check(OrtStatus *status, char *err, size_t errlen) {
  if (!status) return 0;
  set_err(err, errlen, api->GetErrorMessage(status));
  api->ReleaseStatus(status);
  return -1;
}

static void load(void) {
  void *library = dlopen("libonnxruntime.so", RTLD_NOW | RTLD_LOCAL);
  if (!library) {
    snprintf(load_error, sizeof load_error, "libonnxruntime.so could not be loaded: %s", dlerror());
    return;
  }
  typedef const OrtApiBase *(*GetApiBase)(void);
  GetApiBase get_api_base = (GetApiBase)dlsym(library, "OrtGetApiBase");
  const OrtApiBase *base = get_api_base ? get_api_base() : NULL;
  const OrtApi *loaded = base ? base->GetApi(ORT_API_VERSION) : NULL;
  if (!loaded) {
    snprintf(load_error, sizeof load_error, "libonnxruntime.so does not offer ONNX Runtime API version %d",
             ORT_API_VERSION);
    return;
  }
  OrtEnv *created = NULL;
  OrtStatus *status = loaded->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "ScannerCore", &created);
  if (status) {
    snprintf(load_error, sizeof load_error, "%s", loaded->GetErrorMessage(status));
    loaded->ReleaseStatus(status);
    return;
  }
  env = created;
  api = loaded;
}

int sc_ort_load(char *err, size_t errlen) {
  pthread_once(&load_once, load);
  if (api) return 0;
  set_err(err, errlen, load_error);
  return -1;
}

sc_ort_session *sc_ort_session_create(const char *model_path, int intra_op_threads, const char *const *config_keys,
                                      const char *const *config_values, size_t config_count, char *err,
                                      size_t errlen) {
  if (sc_ort_load(err, errlen) != 0) return NULL;
  OrtSessionOptions *options = NULL;
  if (check(api->CreateSessionOptions(&options), err, errlen) != 0) return NULL;
  OrtSession *session = NULL;
  int failed = check(api->SetIntraOpNumThreads(options, intra_op_threads), err, errlen);
  for (size_t i = 0; !failed && i < config_count; i++)
    failed = check(api->AddSessionConfigEntry(options, config_keys[i], config_values[i]), err, errlen);
  if (!failed) failed = check(api->CreateSession(env, model_path, options, &session), err, errlen);
  api->ReleaseSessionOptions(options);
  if (failed) return NULL;
  sc_ort_session *result = malloc(sizeof *result);
  result->session = session;
  return result;
}

void sc_ort_session_free(sc_ort_session *session) {
  if (!session) return;
  api->ReleaseSession(session->session);
  free(session);
}

long sc_ort_session_names(sc_ort_session *session, int output, char ***names, char *err, size_t errlen) {
  OrtAllocator *allocator = NULL;
  size_t count = 0;
  if (check(api->GetAllocatorWithDefaultOptions(&allocator), err, errlen) != 0) return -1;
  if (check(output ? api->SessionGetOutputCount(session->session, &count)
                   : api->SessionGetInputCount(session->session, &count), err, errlen) != 0) return -1;
  char **result = calloc(count ? count : 1, sizeof *result);
  for (size_t i = 0; i < count; i++) {
    char *name = NULL;
    OrtStatus *status = output ? api->SessionGetOutputName(session->session, i, allocator, &name)
                               : api->SessionGetInputName(session->session, i, allocator, &name);
    if (check(status, err, errlen) != 0) {
      for (size_t j = 0; j < i; j++) free(result[j]);
      free(result);
      return -1;
    }
    result[i] = strdup(name);
    allocator->Free(allocator, name);
  }
  *names = result;
  return (long)count;
}

static size_t element_size(int element_type) {
  switch (element_type) {
    case SC_ORT_FLOAT: return sizeof(float);
    case SC_ORT_INT64: return sizeof(int64_t);
    default: return 0;
  }
}

sc_ort_value *sc_ort_value_create(const void *data, size_t bytes, int element_type, const int64_t *shape, size_t rank,
                                  char *err, size_t errlen) {
  if (sc_ort_load(err, errlen) != 0) return NULL;
  size_t elements = 1;
  for (size_t i = 0; i < rank; i++) elements *= (size_t)shape[i];
  if (!element_size(element_type) || elements * element_size(element_type) != bytes) {
    set_err(err, errlen, "The tensor's data does not match its shape and type");
    return NULL;
  }
  OrtAllocator *allocator = NULL;
  if (check(api->GetAllocatorWithDefaultOptions(&allocator), err, errlen) != 0) return NULL;
  OrtValue *value = NULL;
  if (check(api->CreateTensorAsOrtValue(allocator, shape, rank, (ONNXTensorElementDataType)element_type, &value),
            err, errlen) != 0) return NULL;
  void *target = NULL;
  if (check(api->GetTensorMutableData(value, &target), err, errlen) != 0) {
    api->ReleaseValue(value);
    return NULL;
  }
  if (bytes) memcpy(target, data, bytes);
  sc_ort_value *result = malloc(sizeof *result);
  result->value = value;
  return result;
}

void sc_ort_value_free(sc_ort_value *value) {
  if (!value) return;
  api->ReleaseValue(value->value);
  free(value);
}

int sc_ort_session_run(sc_ort_session *session, const char *const *input_names, sc_ort_value *const *inputs,
                       size_t input_count, const char *const *output_names, size_t output_count,
                       sc_ort_value **outputs, char *err, size_t errlen) {
  const OrtValue **in = calloc(input_count ? input_count : 1, sizeof *in);
  OrtValue **out = calloc(output_count ? output_count : 1, sizeof *out);
  for (size_t i = 0; i < input_count; i++) in[i] = inputs[i]->value;
  int failed = check(api->Run(session->session, NULL, input_names, in, input_count, output_names, output_count, out),
                     err, errlen);
  for (size_t i = 0; i < output_count; i++) {
    if (failed) {
      if (out[i]) api->ReleaseValue(out[i]);
      outputs[i] = NULL;
    } else {
      outputs[i] = malloc(sizeof **outputs);
      outputs[i]->value = out[i];
    }
  }
  free(in);
  free(out);
  return failed;
}

const void *sc_ort_value_data(sc_ort_value *value, size_t *bytes, char *err, size_t errlen) {
  OrtTensorTypeAndShapeInfo *info = NULL;
  if (check(api->GetTensorTypeAndShape(value->value, &info), err, errlen) != 0) return NULL;
  size_t elements = 0;
  ONNXTensorElementDataType type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
  int failed = check(api->GetTensorShapeElementCount(info, &elements), err, errlen);
  if (!failed) failed = check(api->GetTensorElementType(info, &type), err, errlen);
  api->ReleaseTensorTypeAndShapeInfo(info);
  if (failed) return NULL;
  size_t size = element_size((int)type);
  if (!size) {
    set_err(err, errlen, "Unsupported tensor element type");
    return NULL;
  }
  void *data = NULL;
  if (check(api->GetTensorMutableData(value->value, &data), err, errlen) != 0) return NULL;
  *bytes = elements * size;
  return data;
}

long sc_ort_value_shape(sc_ort_value *value, int64_t *shape, size_t max_rank, char *err, size_t errlen) {
  OrtTensorTypeAndShapeInfo *info = NULL;
  if (check(api->GetTensorTypeAndShape(value->value, &info), err, errlen) != 0) return -1;
  size_t rank = 0;
  int failed = check(api->GetDimensionsCount(info, &rank), err, errlen);
  if (!failed && rank <= max_rank) failed = check(api->GetDimensions(info, shape, rank), err, errlen);
  api->ReleaseTensorTypeAndShapeInfo(info);
  if (failed) return -1;
  if (rank > max_rank) {
    set_err(err, errlen, "The tensor has too many dimensions");
    return -1;
  }
  return (long)rank;
}

int sc_ort_value_element_type(sc_ort_value *value) {
  OrtTensorTypeAndShapeInfo *info = NULL;
  if (api->GetTensorTypeAndShape(value->value, &info)) return 0;
  ONNXTensorElementDataType type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
  OrtStatus *status = api->GetTensorElementType(info, &type);
  if (status) api->ReleaseStatus(status);
  api->ReleaseTensorTypeAndShapeInfo(info);
  return (int)type;
}
