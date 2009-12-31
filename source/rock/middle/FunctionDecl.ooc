import structs/[Stack, ArrayList]
import ../frontend/Token
import Expression, Type, Visitor, Argument, TypeDecl, Scope,
       VariableAccess, ControlStatement, Return, IntLiteral, Else,
       VariableDecl, Node, Statement, Module, FunctionCall
import tinker/[Resolver, Response, Trail]

FunctionDecl: class extends Expression {

    name = "", suffix = null : String
    returnType := voidType
    type: static Type = BaseType new("Func", nullToken)
    
    /** Attributes */
    isAbstract := false
    isStatic := false
    isInline := false
    isFinal := false
    externName : String = null
    
    typeArgs := ArrayList<VariableDecl> new()
    args := ArrayList<Argument> new()
    returnArg : Argument = null
    body := Scope new()
    
    owner : TypeDecl = null

    init: func ~funcDecl (=name, .token) {
        super(token)
    }
    
    accept: func (visitor: Visitor) { visitor visitFunctionDecl(this) }

    getReturnType: func -> Type { returnType }
    
    getReturnArg: func -> Argument {
        if(returnArg == null) {
            returnArg = Argument new(getReturnType(), generateTempName("returnArg"), token)
        }
        return returnArg
    }
    
    hasReturn: func -> Bool {
        // TODO add Generic support
        //return !getReturnType().isVoid() && !(getReturnType().getRef() instanceof TypeParam);
        returnType != voidType
    }
    
    hasThis:  func -> Bool { isMember() && !isStatic }
    isMember: func -> Bool { owner != null }
    isExtern: func -> Bool { externName != null }
    
    isExternWithName: func -> Bool {
        (externName != null) && !(externName isEmpty())
    }
    
    getType: func -> Type { type }
    
    toString: func -> String {
        name + ": func"
    }
    
    isResolved: func -> Bool { false }
    
    resolveType: func (type: BaseType) {
        
        //printf("** Looking for type %s in func %s with %d type args\n", type name, toString(), typeArgs size())
        
        for(typeArg: VariableDecl in typeArgs) {
            //printf("*** For typeArg %s\n", typeArg name)
            if(typeArg name == type name) {
                //printf("***** Found match for %s in function decl %s\n", type name, toString())
                type suggest(typeArg)
                break
            }
        }
        
    }
    
    resolveAccess: func (access: VariableAccess) {
        
        //printf("Looking for %s in %s\n", access toString(), toString())
        
        if(owner && access name == "this") {
            if(access suggest(owner thisDecl)) return
        }
        
        for(typeArg in typeArgs) {
            if(access name == typeArg name) {
                if(access suggest(typeArg)) return
            }
        }
        
        for(arg in args) {
            if(access name == arg name) {
                if(access suggest(arg)) return
            }
        }
        
        body resolveAccess(access)
    }
    
    resolve: func (trail: Trail, res: Resolver) -> Response {
        
        trail push(this)
        
        //printf("Resolving function decl %s (returnType = %s)\n", toString(), returnType toString())

        for(arg in args) {
            response := arg resolve(trail, res)
            //printf("Response of arg %s = %s\n", arg toString(), response toString())
            if(!response ok()) {
                trail pop(this)
                return response
            }
        }
        
        for(typeArg in typeArgs) {
            response := typeArg resolve(trail, res)
            //printf("Response of typeArg %s = %s\n", typeArg toString(), response toString())
            if(!response ok()) {
                trail pop(this)
                return response
            }
        }
        
        {
            response := returnType resolve(trail, res)
            //printf("))))))) For %s, response of return type %s = %s\n", toString(), returnType toString(), response toString())
            if(!response ok()) {
                trail pop(this)
                return response
            }
        }
        
        {
            response := body resolve(trail, res)
            if(!response ok()) {
                trail pop(this)
                return response
            }
        }
        
        {
            response := autoReturn(trail)
            if(!response ok()) {
                trail pop(this)
                return response
            }
        }
        
        trail pop(this)
        
        return Responses OK
        
    }
    
    autoReturn: func (trail: Trail) -> Response {
        
        if(isMain() && isVoid()) {
            returnType = IntLiteral type
        }
        
        if(!hasReturn() || isExtern()) return Responses OK
        
        stack := Stack<Iterator<Scope>> new()
        stack push(body iterator())
        
        //printf("[autoReturn] Exploring a %s\n", this toString())
        response := autoReturnExplore(stack, trail)
        return response
        
    }
    
    autoReturnExplore: func (stack: Stack<Iterator<Statement>>, trail: Trail) -> Response {
        
        iter := stack peek()
        
        while(iter hasNext()) {
            node := iter next()
            if(node instanceOf(ControlStatement)) {
                cs : ControlStatement = node
                stack push(cs body iterator())
                //printf("[autoReturn] Exploring a %s\n", cs toString())
                autoReturnExplore(stack, trail)
            } else {
                //"[autoReturn] Huh, node is a %s, ignoring\n" format(node class name) println()
            }
        }
        
        stack pop()
        
        // if we're the bottom element, or if our parent doesn't have
        // any other element, we're at the end of control
        condition := stack isEmpty()
        if(!condition) {
            condition = !stack peek() hasNext()
        }
        if(!condition) {
            parentIter := stack peek()
            condition = true
            i := 0
            while(parentIter hasNext()) {
                i += 1
                next := parentIter next()
                if(!next instanceOf(ControlStatement)) {
                    //printf("[autoReturn] next is a %s, condition is then false :/\n", next class name)
                    condition = false
                    break
                }
            }
            while(i > 0) {
                parentIter prev()
                i -= 1
            }
        }
        
        if(condition) {
            list : Scope = iter as ArrayListIterator<Scope> list
            if(list isEmpty()) {
                //printf("[autoReturn] scope is empty, needing return\n")
                returnNeeded(trail)
            }
            
            last := list last()
            
            if(last instanceOf(Return)) {
                //printf("[autoReturn] Oh, it's a %s already. Nice =D!\n",  last toString())
            } else if(last instanceOf(Expression)) {
                expr := last as Expression
                if(expr getType() == null) return Responses LOOP
                
                if(!expr getType() equals(voidType)) {
                    //printf("[autoReturn] Hmm it's a %s\n", last toString())
                    list set(list lastIndex(), Return new(last, last token))
                    //printf("[autoReturn] Replaced with a %s!\n", list last() toString())
                }
            } else if(last instanceOf(Else)) {
                // then it's alright, all cases are already handled
            } else {
                //printf("[autoReturn] Huh, last is a %s, needing return\n", last toString())
                returnNeeded(trail)
            }
        }
        
        return Responses OK
        
    }

    isVoid: func -> Bool { returnType == voidType }
    
    isMain: func -> Bool { name == "main" && suffix == null && !isMember() }
    
    returnNeeded: func (trail: Trail) {
        if(isMain()) {
            body add(Return new(IntLiteral new(0, nullToken), nullToken))
        } else {
            Exception new(This, "Control reaches the end of non-void function! trail = " + trail toString()) throw()
        }
    }
    
    replace: func (oldie, kiddo: Node) -> Bool {
        match oldie {
            case returnType => returnType = kiddo; true
            case => body replace(oldie, kiddo) != null
        }
    }
    
    addBefore: func (mark, newcomer: Node) -> Bool {
        body addBefore(mark, newcomer)
    }
    
    isScope: func -> Bool { true }
    
}
