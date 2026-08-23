let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action, cwd : Text }
in  { targets = [ { mapKey = "sub/app", mapValue = { deps = ["sub/main.c"], phony = False, recipe = [ < Shell = "cc -o app main.c" > ], cwd = "sub" } } ], default = "sub/app" }
