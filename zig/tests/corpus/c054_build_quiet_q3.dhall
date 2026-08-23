let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "quiet_alias", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'alias' > quiet_a.txt" > ] } } ], default = "quiet_alias" }
