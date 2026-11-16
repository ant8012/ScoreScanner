# ONNX Runtime C API headers

`onnxruntime_c_api.h` and `onnxruntime_ep_c_api.h` from ONNX Runtime v1.27.0 (the version the Apple build pins in
`Vendor/onnxruntime/UPSTREAM.json`), unchanged, MIT license (`Vendor/onnxruntime/LICENSE`). Only the Android build
uses them: `sc_ort.c` calls the C API of the `libonnxruntime.so` an Android app packages from Microsoft's
`com.microsoft.onnxruntime:onnxruntime-android:1.27.0`.

SHA-256:
- `onnxruntime_c_api.h` c4ed26d7bbc7b649c1c38622424d88dfb1a28e3d3594c5f1456cf458814e8381
- `onnxruntime_ep_c_api.h` f65ac849718cabe3ff4902698dd2de643c3b3dbe0010242b2b0407548e7ee00c
