let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "explain_e1.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'e1' > explain_e1.txt" > ] } } ], default = "explain_e1.txt" }
