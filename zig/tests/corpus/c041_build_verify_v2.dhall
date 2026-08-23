let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "verify_v2.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'v2' > verify_v2.txt" > ] } } ], default = "verify_v2.txt" }
