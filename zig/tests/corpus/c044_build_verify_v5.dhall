let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "verify_v5.txt", mapValue = { deps = [], phony = False, recipe = [ < Shell = "printf 'v5' > verify_v5.txt && echo SENTINEL > verify_v5_sentinel.txt" > ] } } ], default = "verify_v5.txt" }
