let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "arch-env", mapValue = { deps = [] : List Text, phony = False, recipe = [ < Shell = "echo $DHAKE_ARCH > arch.txt" > ] } } ], default = "arch-env" }
