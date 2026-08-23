let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "explain_e2.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'e2' > explain_e2.txt" > ] } } ], default = "explain_e2.txt" }
