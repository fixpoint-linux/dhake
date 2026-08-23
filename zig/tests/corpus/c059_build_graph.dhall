let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "compile", mapValue = { deps = ["source.c"], phony = False, recipe = [ < Shell = "cc -c source.c" > ] } }
               , { mapKey = "link", mapValue = { deps = ["compile", "main.c"], phony = False, recipe = [ < Shell = "cc -o app compile.o main.c" > ] } }
               , { mapKey = "all", mapValue = { deps = ["link"], phony = True, recipe = [] : List Action } }
               ], default = "all" }
