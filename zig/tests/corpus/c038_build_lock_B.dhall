let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "chain_c", mapValue = { deps = [], phony = False, recipe = [ < Shell = "echo c > chain_c" > ] } }, { mapKey = "chain_b", mapValue = { deps = ["chain_c"], phony = False, recipe = [ < Shell = "echo b > chain_b" > ] } }, { mapKey = "chain_a", mapValue = { deps = ["chain_b"], phony = False, recipe = [ < Shell = "echo a > chain_a" > ] } } ], default = "chain_a" }
