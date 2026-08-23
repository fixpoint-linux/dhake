let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "dhall-env", mapValue = { deps = [] : List Text, phony = False, recipe = [ < Shell = "echo ${env:DHAKE_ARCH} > dhall_arch.txt" > ] } } ], default = "dhall-env" }
