let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, readExec = True, unveil = [] : List Text }
   , targets = [ { mapKey = "fc", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "touch readExec_fc_marker" > ] } } ], default = "fc" }
