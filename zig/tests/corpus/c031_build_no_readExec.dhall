let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, unveil = [] : List Text }
   , targets = [ { mapKey = "no-readExec", mapValue = { deps = [] : List Text, phony = True, recipe = [ < Shell = "echo backward_compat > no_readExec.txt" > ] } } ], default = "no-readExec" }
