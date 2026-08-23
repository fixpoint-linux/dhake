let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "explain_e4_phony", mapValue = { deps = [], phony = True, recipe = [ < Shell = "echo phony ran" > ] } } ], default = "explain_e4_phony" }
