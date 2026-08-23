let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, readExec = True, unveil = [] : List Text }
   , targets = [ { mapKey = "cc-readExec", mapValue = { deps = ["hello_readExec.c"], phony = False, recipe = [ < Shell = "cc -o hello_readExec hello_readExec.c && ./hello_readExec" > ] } } ], default = "cc-readExec" }
