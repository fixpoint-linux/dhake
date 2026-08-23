let Action = < Shell : Text >
let Target = { deps : List Text, phony : Bool, recipe : List Action }
in { sandbox = { enable = True, unveil = [] : List Text }
   , targets = [ { mapKey = "ndn", mapValue = { deps = ["netprobe.c"], phony = False, recipe = [ < Shell = "cc -o netprobe netprobe.c && ./netprobe inet" > ] } } ], default = "ndn" }
