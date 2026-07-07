# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[os, sequtils, strutils]

const
  rootPath = currentSourcePath.parentDir().parentDir().replace('\\', '/')
  libplumPath = rootPath & "/vendor/libplum"
  includePath = libplumPath & "/include/plum"
  srcPath = libplumPath & "/src"

  includes = @["-I" & includePath, "-I" & srcPath]

  defs = @["-DPLUM_STATIC", "-DPLUM_EXPORTS", "-DRELEASE=1", "-D_GNU_SOURCE"]

  pdefs =
    when defined(windows):
      @["-DWIN32_LEAN_AND_MEAN"]
    else:
      @[]

  flags* = (includes & defs & pdefs).mapIt(it.quoteShell()).join(" ")

{.localPassC: flags.}

when defined(windows):
  {.passl: "-lws2_32 -liphlpapi -lbcrypt".}
else:
  {.passl: "-lpthread".}

{.compile(rootPath & "/libplum_units.c", flags).}
{.compile(srcPath & "/http.c", flags).}
{.compile(srcPath & "/upnp.c", flags).}

const
  PLUM_ERR_SUCCESS* = cint(0)
  PLUM_ERR_INVALID* = cint(-1)
  PLUM_ERR_FAILED* = cint(-2)
  PLUM_ERR_NOT_AVAIL* = cint(-3)

  PLUM_MAX_HOST_LEN* = 256
  PLUM_MAX_ADDRESS_LEN* = 64

# Import plum enums with cint size

type
  plum_log_level_t* {.
    importc: "plum_log_level_t", header: "plum.h", size: sizeof(cint)
  .} = enum
    PLUM_LOG_LEVEL_VERBOSE = 0
    PLUM_LOG_LEVEL_DEBUG = 1
    PLUM_LOG_LEVEL_INFO = 2
    PLUM_LOG_LEVEL_WARN = 3
    PLUM_LOG_LEVEL_ERROR = 4
    PLUM_LOG_LEVEL_FATAL = 5
    PLUM_LOG_LEVEL_NONE = 6

  plum_ip_protocol_t* {.
    importc: "plum_ip_protocol_t", header: "plum.h", size: sizeof(cint)
  .} = enum
    PLUM_IP_PROTOCOL_TCP = 0
    PLUM_IP_PROTOCOL_UDP = 1

  plum_state_t* {.importc: "plum_state_t", header: "plum.h", size: sizeof(cint).} = enum
    PLUM_STATE_DESTROYED = 0
    PLUM_STATE_PENDING = 1
    PLUM_STATE_SUCCESS = 2
    PLUM_STATE_FAILURE = 3
    PLUM_STATE_DESTROYING = 4

  plum_mapping_protocol_t* {.
    importc: "plum_mapping_protocol_t", header: "plum.h", size: sizeof(cint)
  .} = enum
    PLUM_MAPPING_PROTOCOL_UNKNOWN = 0
    PLUM_MAPPING_PROTOCOL_PCP = 1
    PLUM_MAPPING_PROTOCOL_NATPMP = 2
    PLUM_MAPPING_PROTOCOL_UPNP = 3
    PLUM_MAPPING_PROTOCOL_DIRECT = 4

  # Define the callback to receive the plum logs
  plum_log_callback_t* = proc(level: plum_log_level_t, message: cstring) {.cdecl.}

  # Define the config struct, passed by copy (usual for struct).
  plum_config_t* {.importc: "plum_config_t", header: "plum.h", bycopy.} = object
    log_level* {.importc: "log_level".}: plum_log_level_t
    log_callback* {.importc: "log_callback".}: plum_log_callback_t
    dummytls_domain* {.importc: "dummytls_domain".}: cstring
    discover_timeout* {.importc: "discover_timeout".}: cint
      # msecs, 0 means use default (10000)
    mapping_timeout* {.importc: "mapping_timeout".}: cint
      # msecs, 0 means use default (10000)
    recheck_period* {.importc: "recheck_period".}: cint
      # msecs, 0 means use default (300000)

  # Define the mapping struct, passed by copy (usual for struct).
  # The user_ptr is a pointer to the MappingHandle in order to receive the result
  plum_mapping_t* {.importc: "plum_mapping_t", header: "plum.h", bycopy.} = object
    protocol* {.importc: "protocol".}: plum_ip_protocol_t
    mapping_protocol* {.importc: "mapping_protocol".}: plum_mapping_protocol_t
    internal_port* {.importc: "internal_port".}: uint16
    external_port* {.importc: "external_port".}: uint16
    external_host* {.importc: "external_host".}: array[PLUM_MAX_HOST_LEN, char]
    user_ptr* {.importc: "user_ptr".}: pointer

  # Define the callback to receive the mapping result
  plum_mapping_callback_t* =
    proc(id: cint, state: plum_state_t, mapping: ptr plum_mapping_t) {.cdecl.}

# Import plum functions

{.push raises: [].}

proc plum_init*(
  config: ptr plum_config_t
): cint {.importc: "plum_init", header: "plum.h".}

proc plum_cleanup*(): cint {.importc: "plum_cleanup", header: "plum.h".}

proc plum_create_mapping*(
  mapping: ptr plum_mapping_t, callback: plum_mapping_callback_t
): cint {.importc: "plum_create_mapping", header: "plum.h".}

proc plum_query_mapping*(
  id: cint, state: ptr plum_state_t, mapping: ptr plum_mapping_t
): cint {.importc: "plum_query_mapping", header: "plum.h".}

proc plum_destroy_mapping*(
  id: cint
): cint {.importc: "plum_destroy_mapping", header: "plum.h".}

proc plum_get_local_address*(
  buffer: cstring, size: csize_t
): cint {.importc: "plum_get_local_address", header: "plum.h".}

{.pop.}
