/** @brief Private ABI; input/output buffers are borrowed for one synchronous call. */
part of Ngit;
@extern("C") func ngit_prepare_snapshot(
  origin: *const int8,
  origin_len: int32,
  revision: *const int8,
  revision_len: int32,
  store: *const int8,
  store_len: int32,
  offline: int32,
  timeout_ms: int32,
  output: *mut int8,
  capacity: int32
) -> int32;
