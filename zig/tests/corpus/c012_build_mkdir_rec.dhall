let Action = < Shell : Text | Mkdir : < Plain : Text | Parents : { path : Text, parents : Bool } > | Rm : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { targets = [ { mapKey = "m", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Mkdir = < Parents = { path = "a/b/c", parents = True } > > ] } } ], default = "m" }
