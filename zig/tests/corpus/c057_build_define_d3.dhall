let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in  { targets = [ { mapKey = "define_d3", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "test -z \"$DEBUG\" && printf 'ok' > leaked.txt" > ] } } ], default = "define_d3" }
