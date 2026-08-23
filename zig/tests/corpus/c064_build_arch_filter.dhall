let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, arch : Text }
in  { targets = [ { mapKey = "native", mapValue = { deps = [] : List Text, phony = False, recipe = [ < Shell = "touch native.out" > ], arch = "x86_64" } }, { mapKey = "arm", mapValue = { deps = [] : List Text, phony = False, recipe = [ < Shell = "touch arm.out" > ], arch = "aarch64" } } ], default = "native" }
