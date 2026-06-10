import std/[os, strutils]

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
  let
    cflags = "-std=c11 -O2 -pthread -fPIC -fvisibility=hidden -DPLUM_EXPORTS -DPLUM_STATIC -DRELEASE=1 -D_GNU_SOURCE"
    includes = "-Iinclude/plum -Isrc"

  withDir "vendor/libplum":
    let winFlags =
      if defined(windows): " -DWIN32_LEAN_AND_MEAN"
        else: ""
    var oFiles: seq[string]

    for srcFile in listFiles("src"):
      if srcFile.endsWith(".c"):
        let oFile = srcFile.changeFileExt("o")
        exec "gcc " & cflags & winFlags & " " & includes & " -c " & srcFile & " -o " & oFile
        oFiles.add(oFile)

    exec "ar rcs libplum.a " & oFiles.join(" ")

task format, "format Nim code using nph":
  exec "nph libplum/ tests/"

task buildBundledLibs, "build bundled libraries":
  compileStaticLibraries()

task test, "run tests":
  compileStaticLibraries()
  exec("nimble setup")
  exec("nim c -o:tests/test_plum tests/test_plum.nim")
  exec("./tests/test_plum")

task testIntegration, "run miniupnpd integration tests in Docker / Podman":
  let docker = if findExe("podman") != "": "podman" else: "docker"
  exec(docker & " build -t " & packageName & " -f tests/Dockerfile .")
  proc envFlag(name: string): string =
    if getEnv(name) != "": " -e " & name & "=" & getEnv(name) else: ""
  let flags = envFlag("TEST_VERBOSE") & envFlag("MINIUPNPD_VERBOSE") & envFlag("LIBPLUM_VERBOSE")
  exec(docker & " run --rm --cap-add=NET_ADMIN -e TEST_MINIUPNP_PCP=1" & flags & " " & packageName)
  exec(docker & " run --rm --cap-add=NET_ADMIN -e TEST_MINIUPNP_UPNP=1" & flags & " " & packageName)
  exec(docker & " run --rm --cap-add=NET_ADMIN -e TEST_MINIUPNP_NATPMP=1" & flags & " " & packageName)

before install:
  compileStaticLibraries()
