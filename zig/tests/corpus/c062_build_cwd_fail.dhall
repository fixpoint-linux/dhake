let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, cwd : Text }
in  { targets = [ { mapKey = "fail", mapValue = { deps = [], phony = False, recipe = [ < Shell = "echo hello" > ], cwd = "nonexistent-dir" } } ], default = "fail" }
