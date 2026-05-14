mode = ScriptMode.Verbose

packageName   = "libplum"
version       = "0.0.1"
author        = "Status Research & Development GmbH"
description   = "Nim binding for libplum (PCP, NAT-PMP, UPnP-IGD port mapping)"
license       = "Apache License 2.0 or MIT"
installDirs   = @["libplum", "vendor"]

### Dependencies
requires "nim >= 1.6.0",
         "results >= 0.4.0",
         "chronos >= 4.2.0 & < 5.0.0",
         "unittest2"

proc compileStaticLibraries() =
  withDir "vendor/libplum":
    exec("cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF")
    exec("cmake --build build")

task buildBundledLibs, "build bundled libraries":
  compileStaticLibraries()

task test, "run tests":
  compileStaticLibraries()
  exec("nimble setup")
  exec("nim c -r tests/test_plum.nim")

before install:
  compileStaticLibraries()
