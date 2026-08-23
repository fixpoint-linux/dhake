let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "quiet_b1", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'q1' > quiet_b1.txt" > ] } } ], default = "quiet_b1" }
