let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "quiet_fail", mapValue = { deps = [], phony = False, recipe = [ < Shell = "exit 1" > ] } } ], default = "quiet_fail" }
