let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "watch_out.txt", mapValue = { deps = ["watch_src.txt"], phony = False, recipe = [ < Shell = "cat watch_src.txt > watch_out.txt" > ] } } ], default = "watch_out.txt" }
