mode = ScriptMode.Verbose

packageName   = "libplum"
version       = "0.6.2"
author        = "Status Research & Development GmbH"
description   = "Nim binding for libplum (PCP, NAT-PMP, UPnP-IGD port mapping)"
license       = "Apache License 2.0 or MIT"
installDirs   = @["libplum", "vendor"]
installFiles  = @["libplum_units.c"]

### Dependencies
requires "nim >= 1.6.0",
         "results >= 0.4.0",
         "chronos >= 4.2.0 & < 5.0.0",
         "unittest2"

task format, "format Nim code using nph":
  exec "nph libplum/ tests/"

task test, "run tests":
  exec("nimble setup")
  exec("nim c -o:tests/test_plum tests/test_plum.nim")
  exec("./tests/test_plum")

task testRefc, "run tests under refc":
  exec("nimble setup")
  exec("nim c --mm:refc -d:useGcAssert -o:tests/test_plum_refc tests/test_plum.nim")
  exec("./tests/test_plum_refc")

task testIntegration, "run miniupnpd integration tests in Docker / Podman":
  let docker = if findExe("podman") != "": "podman" else: "docker"
  exec(docker & " build -t " & packageName & " -f tests/Dockerfile .")
  proc envFlag(name: string): string =
    if getEnv(name) != "": " -e " & name & "=" & getEnv(name) else: ""
  let flags = envFlag("TEST_VERBOSE") & envFlag("MINIUPNPD_VERBOSE") & envFlag("LIBPLUM_VERBOSE")
  exec(docker & " run --rm --cap-add=NET_ADMIN -e TEST_MINIUPNP_PCP=1" & flags & " " & packageName)
  exec(docker & " run --rm --cap-add=NET_ADMIN -e TEST_MINIUPNP_UPNP=1" & flags & " " & packageName)
  exec(docker & " run --rm --cap-add=NET_ADMIN -e TEST_MINIUPNP_NATPMP=1" & flags & " " & packageName)
