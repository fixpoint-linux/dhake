let Action = < Shell : Text | Rm : { path : Text, recursive : Bool } >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "r", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Rm = { path = "does-not-exist", recursive = True } > ] } } ], default = "r" }
