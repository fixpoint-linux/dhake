let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, denyNetwork = True, unveil = [] : List Text }
   , targets = [ { mapKey = "dnfc", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "touch denyNetwork_fc_marker" > ] } } ], default = "dnfc" }
