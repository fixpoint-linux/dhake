let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "explain_e3", mapValue = { deps = ["explain_e3_src.c"], phony = False, recipe = [ < Shell = "cc -o explain_e3 explain_e3_src.c" > ] } } ], default = "explain_e3" }
