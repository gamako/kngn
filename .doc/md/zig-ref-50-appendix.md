# Appendix

## Containers

 

 A container in Zig is any syntactical construct that acts as a namespace to hold [variable](#Container-Level-Variables) and [function](#Functions) declarations.
 Containers are also type definitions which can be instantiated.
 [Structs](#struct), [enums](#enum), [unions](#union), [opaques](#opaque), and even Zig source files themselves are containers.
 

 

 Although containers (except Zig source files) use curly braces to surround their definition, they should not be confused with [blocks](#Blocks) or functions.
 Containers do not contain statements.
 

 

 
## Grammar

 
```zig
Root =] skip
EQUALEQUAL ' skip
EXCLAMATIONMARK |] skip
MINUSEQUAL ' skip
PERCENT ' ![>=] skip
RARROW2 >' ![=] skip
RARROW2EQUAL >=' skip
RARROWEQUAL =' skip
RBRACE