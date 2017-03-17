# Where all the SAST nodes are kept.
# Most of the have to be in the same file because they depend on each other.
need Spit::Exceptions;
use Spit::Constants;
need DispatchMap;
need Spit::SpitDoc;

use Spit::Metamodel;

sub class-by-name($name) {
    with $*SETTING.lookup(CLASS,$name) {
        .class
    } else {
        die "internal error: class $name used before it's declared";
    }
}

# A pair where the value has container we can mess with
sub cont-pair($a,$b is copy) { $a => $b }

# We can't know the class definition at p6 compile time yet so we
# have to get and store them at runtime.
# This solution works as long as there is only one definition
# per run which is true for now.
sub tAny is export { state $ = class-by-name('Any')   }
sub tInt is export { state $ = class-by-name('Int')   }
sub tStr is export { state $ = class-by-name('Str')   }
sub tBool is export { state $ = class-by-name('Bool') }
multi tList is export { state $ = class-by-name('List') }
multi tList(Spit::Type \param) {
    my $glist = tList();
    $glist.^parameterize(param);
}
sub tRegex is export { state $ = class-by-name('Regex') }
sub tOS is export { state $ = class-by-name('OS') }
sub tFD is export { state $ = class-by-name('FD') }
sub tFile is export { state $ = class-by-name('File')  }
sub tEnumClass is export { state $ = class-by-name('EnumClass')  }

class SAST::IntExpr   {...}
class SAST::Var       {...}
class SAST::Block     {...}
class SAST::Param     {...}
class SAST::Nop       {...}
class SAST::Return    {...}
class SAST::Signature {...}
class SAST::MethodCall {...}
class SAST::IVal      {...}
class SAST::BVal       {...}
class SAST::SVal {...}

class SAST::Blessed      {...}
class SAST::List {...}
class SAST::ClassDeclaration {...}
class SAST::Concat {...}
class SAST::PhaserBlock {...}
class SAST::Invocant {...}
class SAST::Type {...}
class SAST::RoutineDeclare { ... }
class SAST::CmpRegex {...}
class SAST::Cmd {...}

role SAST is rw {
    has Match:D $.match is required is rw;
    has %.ann; # a place to put stuff that doesn't fit anywhere
    has $.stage2-done is rw;
    has $.stage3-done is rw;
    has $.cloned is rw;
    has Spit::Type $.ctx; # The type context the object was put in in stage2
    has $.included is rw;
    has @.extra-depends;

    method do-stage2(Spit::Type \ctx,:$desc,|args){
        X::AdHoc.new(
            payload => "node {self.WHICH} ({self.gist}) re-stage2. First stage2 at:\n $!stage2-done",
        ). throw if $.stage2-done;
        X::AdHoc.new(
            payload => "node of type {self.^name} stage2 with Spit::Type type object",
        ).throw if ctx === Spit::Type;
        $.stage2-done = Backtrace.new;
        $!ctx = ctx;
        my SAST:D $res = self.stage2(ctx,|args);
        $res = coerce $res,ctx,:$desc;
        $res;
    }

    method stage2($) { self }

    method new(Match :$match? is copy,|a) {
        if not $match {
            my $tmp = OUTER::CALLER::LEXICAL::<$/>;
            $match = $tmp // Nil;
        }
        self.bless(:$match,|a);
    }
    # A Bool is never the topic
    method topic { $.type ~~ tBool() ?? Nil !! self }

    method assign-type { IMMUTABLE }
    method assignable  { self.assign-type !== IMMUTABLE }
    method compile-time { Nil }
    method gist { self.node-name }
    method spit-gist { self.gist }
    method node-name { self.^name.subst(/^'SAST::'/,'') }
    method itemize { True }
    method depends { Empty }
    method all-deps { self.depends }
    method type {...} # The type for type checking
    method ostensible-type { self.type } # The the type that the thing looks like
    method deep-clone { self.clone }
    method deep-first(\needle) { self if self ~~ needle }

    # Convenience methods
    method stage2-node(\type,|args) {
        type.new(:stage2-done,:$.ctx,:$.match,|args);
    }

    method stage3-node(\type,|args) {
        type.new(
            :stage2-done,
            :stage3-done,
            :!cloned,
            :$.ctx,
            :$.match,
            |args,
        )
    }
    method uses-Str-Bool {
        self.type.^find-spit-method('Bool') === tStr().^find-spit-method('Bool');
    }

    method make-new(\type,|args){
        type.new(
            :$.match,
            |args,
        );
    }

    # used in stage3 to replace one node with another in the AST
    method switch(SAST:D $self is rw: $b is copy) {
        if $b.type !=== $self.type {
            $b = $self.stage3-node(SAST::Blessed,class-type => $self.type,$b);
        }
        $b.extra-depends.append($self.extra-depends);
        $self = $b;
    }
}
role SAST::Assignable {
    has SAST $.assign is rw;
    has SAST $.assign-mod is rw;

    method assign-type { ... }
}

# makes sure $node is ~~ $type.primative or coerces it to it OR throws a type exception
sub coerce(SAST:D $node,Spit::Type $type,:$desc) {
    my $target-prim = $type.primitive;
    X::AdHoc.new( payload => "{$node.^name} {try $node.gist} gave a literal Spit::Type type object").throw
        if $node.type === Spit::Type;
    X::AdHoc.new( payload => "{$node.^name} returned it's type as something that isn't a Spit::Type ({$node.type.^name}) ").throw
        if $node.type !~~ Spit::Type;

    if $node.type.primitive ~~ $target-prim {
        # all good
        $node;
    } else {
        if $node.type.^find-spit-method($target-prim.^name) -> $meth {
            # We got a coercer method, wrap this node in it and call it
            my $call = SAST::MethodCall.new(
                match => $node.match,
                name => $target-prim.^name,
                $node,
            );
            $call.set-declaration($meth);
            return $call.do-stage2($target-prim,:$desc);
        }
        else {
            # We need node to become a list. As long as the node matches the List's
            # element type we can just bless this node into a List[of-the-appropriate type]
            if $type ~~ tList() and $node.type !~~ tList() {
                my $elem-type := derive-type($type);
                my $list-type = $type === tList() ?? tList($elem-type) !! $type;
                SAST::Blessed.new(
                    class-type => $list-type,
                    match => $node.match,
                    :stage2-done,
                    coerce($node,$elem-type,:desc<coercing to a list>),
                );
            }
            # we lose
            else {
                SX::TypeCheck.new(
                    :$node,
                    :$desc,
                    got => $node.type.^name,
                    expected => $target-prim.^name,
                ).throw
            }
        }
    }
}

sub derive-type(Spit::Type $_) {
    when tList() { .parameterized ?? .params[0] !! tStr() }
    default { $_ }
}

sub type-from-sigil(Str:D $sigil --> Spit::Type) {
    do given $sigil {
        when '$' { tStr() }
        when '@' { tList() }
        default { die "got bogus sigil '$sigil'" }
    };
}

sub symbol-type-from-sigil(Str:D $_ --> SymbolType) {
    when '$' { SCALAR }
    when '@' { ARRAY  }
    default { die "got boigus sigil '$_'" }
}

sub itemize-from-sigil(Str:D $_ --> Bool:D) {
    when '@' { False }
    default { True }
}

# XXX: why are there two? This can be done better.
role SAST::Dependable {
    has $.referenced is rw;
    has $.depended is rw;
    method dont-depend { False }
}
role SAST::Declarable does SAST::Dependable {
    has $.declared-in is rw;
    has SpitDoc:D @.docs;
    method symbol-type {...}
    method name {...}
}

role SAST::OSMutant {
    method mutate-for-os($os) {...}
}

class SAST::Children does SAST {

    method children { Empty }
    method gist(Mu:D:){
        my $name = self.^name.subst(/^'SAST::'/,'');
        $name ~ "$.gist-children";
    }

    method gist-children {
        if @.children {
            my $parent-pad = CALLERS::<$*gpad> || '';
            my $*gpad = $parent-pad ~ "  ";
            "\n$*gpad" ~ '- ' ~ @.children.map(*.gist).join("\n$*gpad" ~ '- ')
        }
    }

    method type { tAny }

    method all-deps {
        # XXX: THIS IS HORRIBLE AND HAS TO DIE ASAP. NEED TO USE LEXICAL ANALYSIS INSTEAD.
        (|@.children.map(*.all-deps).flat,|self.depends).grep({ $_ !~~ SAST::Param|SAST::Invocant });
    }

    method descend($self is rw: &block) {
        &block($self);
        for $self.children {
            when SAST::Children { .descend(&block) }
            default { &block($_) }
        }
    }

    method deep-clone(|c){
        my \ret := self.clone(|c);
        for ret.children {
            $_ .= deep-clone;
        }
        ret;
    }

    method deep-first(\needle){
        return self if self ~~ needle;
        for @.children {
            .return with .deep-first(needle);
        }
    }
}

class SAST::MutableChildren  is SAST::Children {
    has SAST:D @.nodes handles <append prepend push pop shift unshift AT-POS elems>;

    method children { @!nodes }
    method new(*@nodes,Match :$match? is copy,|a) {
        my $tmp = CALLER::LEXICAL::<$/>;
        $match ||= $tmp // Nil;
        self.bless(:@nodes,:$match,|a);
    }

    method clone(|c){ callwith(|c,:@!nodes) }
}

class SAST::CompUnit is SAST::Children {
    has SAST:D $.block is required is rw;
    has $.depends-on is rw; # A Spit::DependencyList
    has @.phasers;
    has @.exported;
    has $.name is required;

    method do-stage2 {
        my $*CU = self;
        $!block .= do-stage2(tAny());
        self.stage2-done = True;
        self;
    }

    method children { $!block, }

    method type { tAny }

    multi method export(SymbolType $type,$name,$value)  {
        @!exported[$type]{$name} = $value;
    }

    multi method export(SAST::Declarable:D $d) {
        self.export($d.symbol-type,$d.name,$d);
    }

    method gist { callsame() ~ ("\ndepends:\n" ~ $!depends-on.gist if $!depends-on) ~ "\n" }
}



class SAST::Var is SAST::Children does SAST::Assignable {
    has $.name is required;
    has Sigil:D $.sigil is required;
    has $.declaration;

    method symbol-type {
        given $!sigil {
            when '$' { SCALAR }
            when '@' { ARRAY  }
            when '&' { SUB    }
        }
    }

    method assign-type { $!sigil eq '@' ?? LIST-ASSIGN !! SCALAR-ASSIGN }

    method stage2($ctx) is default {
        with $.assign-mod {
            my $clone = self.declaration.gen-reference(:$.match);
            .append($clone,$.assign);
            $.assign = $_;
        }
        $_ .= do-stage2(self.type,:$.desc) with $.assign;
        self;
    }

    method gist { $.node-name ~ "($.spit-gist)" ~ (' = ' if $.assign) ~ $.gist-children }

    method spit-gist { "$!sigil$!name" }

    method declaration is rw {
        $!declaration //= $*CURPAD.lookup(self.symbol-type,$!name,:$.match);
    }

    method type { self.declaration.type }

    method children { list $.assign // Empty  }

    method depends { $.declaration, }

    method is-option  { $!name.starts-with('*') }
    method bare-name  { $!name.subst(/^'*'/,'') }
    method gen-reference(:$match!,|c){
        SAST::Var.new(:$.name,:$.sigil,:$match,:$.declaration,|c);
    }

    method desc { "Assignment to $.spit-gist" }

    method itemize { itemize-from-sigil($!sigil) }
}

class SAST::VarDecl is SAST::Var does SAST::Declarable is rw {
    has Spit::Type $.type;
    has Spit::Type $.decl-type;
    has $.dont-depend is rw;

    method stage2(SAST::VarDecl:D: $ctx) is default {
        my $sigil-type := type-from-sigil(self.sigil);
        if $!decl-type {
            $!type = do if $sigil-type === tList() {
                tList($!decl-type);
            } else {
                $!decl-type;
            }
            $.assign .= do-stage2($!type,:$.desc) if $.assign;
        } else {
            $!type = do if $.assign {
                $.assign .= do-stage2($sigil-type,:$.desc);
                $.assign.type;
            } else {
                if $sigil-type === tList() {
                    tList(tStr);
                } else {
                    $sigil-type;
                }
            }
        }
        self;
    }

    method dont-depend is rw { $!dont-depend }
    method depends { Empty }
    method declaration { self }
}

class SAST::MaybeReplace is SAST::VarDecl {
    method writable { $.assign }

    method replace-with {
        given $.assign {
            when *.compile-time.defined { $_ }
            when { .compile-time ~~ Spit::Type } { $_ }
            when SAST::Var|SAST::Param|SAST::Invocant { $_ }
            default { Nil }
        }
    }
}

class SAST::ConstantDecl is SAST::VarDecl {
    method inline-value {
        self.assign if self.assign andthen .compile-time;
    }
    method assign-type { IMMUTABLE }
}

class SAST::Block is SAST::MutableChildren does SAST::Dependable {
    has @.symbols;
    has $.outer is rw;

    multi method lookup(SymbolType $type,Str:D $name,Match :$match) {
        @!symbols[$type]{$name}
        || self.outer.?lookup($type,$name,:$match)
        || ( $match && SX::Undeclared.new(
            :$name,
            :$type
            :$match,
        ).throw)
        || Nil
    }

    multi method lookup(SAST::Declarable:D $sast) {
        samewith($sast.symbol-type,$sast.name,match => $sast.match)
    }

    method declare(SAST::Declarable:D $sast) {
        with @!symbols[$sast.symbol-type]{$sast.name} {
            SX::Redeclaration.new(
               name => $sast.name,
               type => $sast.symbol-type,
               match => $sast.match,
               orig-match => .match
            ).throw;
        } else {
            $sast.declared-in = self;
            $_ = $sast;
        }
    }

    method symbol(SymbolType $type,Str:D $name) {
        @!symbols[$type]{$name};
    }

    method stage2($ctx,:$desc) is default {
        my $*CURPAD = self;
        my $returns := self.last-stmt;
        for @.children {
            $_ .= do-stage2(tAny) unless $_ =:= $returns;
        }
        if $returns {
            $returns = SAST::Return.new(val => $returns,match => $returns.match) if $ctx !=== tAny;
            $returns .= do-stage2($ctx,:desc<return value of block>);
        }
        self;
    }

    method returns is rw {
        with self.last-stmt {
            when SAST::Return { $_ }
            default { Nil}
        }
    }

    method last-stmt is rw {
         @.children.reverse.first({ $_ !~~ SAST::PhaserBlock });
    }

    method one-stmt is rw {
        if @.children.grep({$_ !~~ SAST::PhaserBlock}) == 1 {
            given self.last-stmt {
                when SAST::Return { .val }
                default { $_ }
            }
        }
    }

    method type {
        my $*CURPAD = self;
        if self.returns -> $_ {
            .type
        } else {
            tAny;
        }
    }

    method gist {
        $.node-name ~ " --> {$.type.^name}" ~ $.gist-children;
    }
}

class SAST::PhaserBlock is SAST::Children {
    has $.block is required;
    has Spit-Phaser $.stage is required;

    method stage2 ($) { $!block .= do-stage2(tAny); self }
    method children { $!block, }
    method type { tAny() }
}

class SAST::Return is SAST::Children {
    has $.val is rw;
    has $.impure is rw;
    method stage2($ctx) is default {
        self.val .= do-stage2($ctx,:desc("Return value didn't match block's return type"));
        self;
    }
    method type { $!val.type }
    method children { $!val, }
}

# Array element
class SAST::Elem is SAST::MutableChildren does SAST::Assignable {
    has SAST $.index is required;

    method assign-type { SCALAR-ASSIGN }

    method stage2($ctx) {
        SX::NYI.new(feature => 'element assignment modifiers',node => $_).throw with $.assign-mod;
        $!index .= do-stage2(tInt);
        $.elem-of .= do-stage2(tAny);
        with $.assign {
            $_ .= do-stage2(derive-type($.elem-of.type),:desc("assigning to element of {$.elem-of.gist}"));
        }
        self;
    }

    method gist { $.elem-of.gist ~ '[' ~ $!index.gist ~ ']' }
    method type { derive-type($.elem-of.type) }
    method elem-of is rw { @.nodes[0] }
    method children { $.elem-of,$!index, ($.assign // Empty) }
    method spit-gist { $.elem-of.spit-gist ~ '[' ~ $!index.spit-gist ~ ']' }
}

class SAST::WriteToFile is SAST::Children is rw {
    has SAST @.write;
    has SAST @.append;
    has SAST $.in;

    method stage2($ctx) is rw {
        $_ .= do-stage2(tStr) for @.children;
        self;
    }

    method children { (|@!append,|@!write,$!in).grep(*.defined) }

    method clone(|c) { callwith(|c,:@!write,:@!append) }

    method type { tAny }
}

class SAST::Cmd is SAST::MutableChildren is rw {
    has SAST $.cmd;
    has SAST $.in;
    has SAST @.write;
    has SAST @.append;
    has SAST %.set-env;

    method stage2($ctx) is default {
        $_ .= do-stage2(tStr) for ($!cmd,$!in,|@.nodes,|%!set-env.values).grep(*.defined);

        for |@!write,|@!append <-> $in,$out {
            $in  .= do-stage2(tFD, :desc<Output redirection source>);
            $out .= do-stage2(tStr,:desc<Output redirection destination>);
        }
        self;
    }

    method children {
        ($!cmd,|@.nodes,$!in,|@!write,|@!append,|%!set-env.values).grep(*.defined)
    }

    method clone(|c) { callwith(|c,:@!write,:@!append,:%!set-env) }

    method type { $.ctx }
}

class SAST::Coerce is SAST::MutableChildren {
    has Spit::Type $.to is required;
    method type { $!to }
    method stage2 ($) {
        self[0] .= do-stage2($!to);
        self[0];
    }
    method gist { $.node-name ~ "({$!to.name})" ~ $.gist-children }
}

class SAST::Cast is SAST::MutableChildren {
    has Spit::Type $.to is required;

    method type { $!to }
    method stage2 ($) {
        self[0] .= do-stage2(tStr());
        self;
    }
    method gist { $.node-name ~ "({$!to.name})" ~ $.gist-children }
}

# Negation
class SAST::Neg is SAST::MutableChildren {
    method type { tBool }

    method stage2 ($) {
        self[0] .= do-stage2(tBool);
        self;
    }

    method topic { self[0].topic }
}

# Negative number
class SAST::Negative is SAST::MutableChildren {
    has $.as-string;
    method type { self[0].type }
    method stage2 ($ctx) {
        $!as-string = SAST::Concat.new(SAST::SVal.new(val => '-',:$.match,:stage2),self[0],:$.match,:stage2);
        self[0] .= do-stage2(tInt);
        self;
    }
}

class SAST::RoutineDeclare is SAST::Children does SAST::Declarable does SAST::OSMutant {
    has Str $.name is required;
    has SAST::Signature $.signature is rw;
    has Spit::Type $.return-type is rw = tAny();
    has @.os-candidates is rw;
    has $.is-native is rw;
    has $.chosen-block is rw;
    has $.impure is rw;

    method symbol-type { SUB }

    method gist { "sub {$!name}\(" ~ $!signature.gist ~ '){ ... }' }
    method spit-gist { "sub {$.name}\({$.signature.spit-gist})" }

    method stage2($) {
        $!signature.do-stage2(tAny);
        # make os-candidates into a list of writable pairs
        @!os-candidates .= flatmap: -> $os,$block { cont-pair $os,$block };
        for @.os-candidates {
            .value .= do-stage2(
                $!is-native ?? tAny()
                !! $.return-type,
                :desc("Return value of block didn't match return type of $!name"));
            with .value.returns {
                .impure = $!impure;
            }
        }
        self;
    }
    method type { tAny }

    method mutate-for-os(Spit::Type $os) {
        $!chosen-block = self.block-for-os($os) // False;
        Nil;
    }

    method children {
        ($!chosen-block // |@!os-candidates.map(*.value) || Empty),$!signature;
    }
}

class SAST::MethodDeclare is SAST::RoutineDeclare {
    has $.rw is rw;
    has $.static is rw;
    has SAST::ClassDeclaration $.invocant-type is rw;
    has @.invocants;

    method gist { "method {$.name}\({$.signature.gist})\{ ... \}" }
    method spit-gist { "method {$.name}\({$.signature.spit-gist})" }

    method stage2($) {
        $.signature.has-invocant = True unless $!static;
        $.return-type = $.invocant-type.class if $!rw;
        $_ .= do-stage2(tAny) for @!invocants;
        nextsame;
    }

    multi method reified-return-type(:$reify!) {
        my $return-type = self.return-type;
        if $reify.parameterized and $return-type.HOW ~~ Spit::Metamodel::Placeholder {
            $reify.params[$return-type.^param-pos]
        } else {
            $return-type
        }
    }

    method block-for-os($os) {
        $!invocant-type.class.^dispatcher.get(self.name,$os);
    }

    method declarator { 'method' }

    method children { |callsame,|@!invocants }
}


class SAST::SubDeclare is SAST::RoutineDeclare {
    has $!dispatcher;

    method dispatcher {
        $!dispatcher //= DispatchMap.new(tmp => self.os-candidates).compose;
    }
    method block-for-os($os) {
        self.dispatcher.get('tmp',$os);
    }

    method declarator { 'sub' }
}

class SAST::Call  is SAST::Children {
    has SAST:D %.named;
    has SAST:D @.pos;
    has SAST::RoutineDeclare $.declaration is rw;
    has Str:D $.name is required;

    method stage2($ctx) is default {
        my $signature := self.gen-sig;
        my (@pos-params,%named-params) := ($signature.pos,$signature.named);
        my $slurpy = @pos-params ?? @pos-params[*-1].slurpy !! False;

        my $pos-args := @!pos.iterator;
        my $last-valid;
        for @pos-params.kv -> $i,$param {
            if $param.slurpy {
                my $elem-type = derive-type($param.type);
                until (my $arg := $pos-args.pull-one) =:= IterationEnd {
                    $arg .= do-stage2(
                        $elem-type,
                        :desc("Argument slurped by {$param.spit-gist} " ~
                              "in {$.declaration.spit-gist} doesn't match its type")
                    );
                }
            } else {
                if (my $arg := $pos-args.pull-one) !=:= IterationEnd {
                    $arg .= do-stage2(
                        $param.type,
                        :desc("Argument {$i + 1} to {$.declaration.spit-gist} doesn't match its type")
                    );
                    $last-valid := $arg;
                } else {
                    SX::BadCall.new(
                        :$.declaration,
                        reason => "Not enough positional arguments. Expected {@pos-params.elems}, got {@!pos.elems}.",
                        match => ($last-valid andthen .match or $.match),
                        after => ?$last-valid,
                    ).throw;
                }
            }
        }

        if (my $extra-arg := $pos-args.pull-one) !=:= IterationEnd {
            SX::BadCall.new(
                :$.declaration,
                reason => "Too many positional arguments. Expected {@pos-params.elems}, got {@!pos.elems}.",
                match => $extra-arg.match,
            ).throw;
        }

        for %!named.kv -> $name,$arg is rw {
            if %named-params{$name} -> $param {
                $arg .= do-stage2(
                    $param.type,
                    :desc("Named argument {$param.spit-gist} to $!name doesn't match its type")
                );
            } else {
                SX::BadCall.new(
                    :$.declaration,
                    reason => "Unexpected named argument '$name'.",
                    match => $arg.match,
                ).throw;
            }
        }
        self;
    }

    # gets a list of named params from the declaration and pairs them
    # up with the corresponding named args
    method param-arg-pairs {
        %!named.kv.map: -> $name,$arg {
            do if $.declaration.signature.named{$name} -> $param {
                $param => $arg
            }
        }
    }

    method type {
        self.declaration.return-type;
    }

    method declaration is rw { $!declaration //= self.find-declaration;}
    method set-declaration(SAST::RoutineDeclare:D $!declaration) { }

    method clone(|c){ callwith(|c,:@!pos,:%!named) }

    method depends { $.declaration, }

    method gen-sig { self.declaration.signature }

    method gist { $.node-name ~ "($!name)" ~ $.gist-children }
}

class SAST::MethodCall is SAST::Call is SAST::MutableChildren {
    has $!gen-sig;
    has $!type;

    method invocant is rw { self[0] }
    method type { $!type ||= self.declaration.reified-return-type(:reify($.invocant.type)) }
    method gen-sig {
        $!gen-sig //= do {
            my $sig = self.declaration.signature;
            if $.invocant.type.parameterized {
                $sig := $sig.clone;
                for $sig.children {
                    $_ .= clone;
                    if .type.HOW ~~ Spit::Metamodel::Placeholder {
                        .type = .type.^reify($.invocant.ostensible-type);
                    }
                }
                $sig;
            } else {
                $sig;
            }
        }
    }

    method stage2($ctx) {
        $.invocant .= do-stage2(tAny) unless $.invocant.stage2-done;
        if not $.declaration.static and $.invocant.WHAT === SAST::Type and !$.invocant.ostensible-type.enum-type {
            SX.new(message => q|Instance method called on a type.|,:$.match).throw;
        }
        callsame;
    }

    method find-declaration {
        $.invocant.ostensible-type.^find-spit-method($.name,:$.match);
    }

    method children { $.invocant,|@.pos,|%.named.values }

    method topic {
        if $.type ~~ tBool() {
            $.invocant.topic
        } else {
            self;
        }
    }

    method spit-gist { ".$.name" ~ "\(...)" }
}

class SAST::SubCall is SAST::Call {

    method find-declaration {
        $*CURPAD.lookup(SUB,$.name,:$.match);
    }

    method children { |@.pos,|%.named.values }

    method spit-gist { $.name ~ "(...)" }
}

class SAST::Invocant does SAST does SAST::Declarable {
    has $.sigil is required;
    has $.class-type is required;
    method name { 'self' }
    method symbol-type { symbol-type-from-sigil($!sigil) }
    method gist { $.node-name ~ "($.spit-gist)" }
    method spit-gist { "{$!sigil}self" }
    method type { $!class-type }
    method dont-depend { True }
    method stage2 ($) { self }
    method itemize { itemize-from-sigil($!sigil) }
}

class SAST::Param does SAST does SAST::Declarable {
    has Str:D $.name is required;
    has Sigil:D $.sigil is required;
    has $.signature is rw;
    has $.type is rw = type-from-sigil(self.sigil);
    method stage2 ($) { self }
    method symbol-type { symbol-type-from-sigil($!sigil) }
    method dont-depend { True }

    method gist { $.node-name ~ "($.spit-gist)" }
    method itemize { itemize-from-sigil($!sigil) }
}

class SAST::PosParam is SAST::Param {
    has $.slurpy;
    has Int $.ord is rw;

    method spit-gist { ('*' if $!slurpy) ~ "$.sigil$.name" }
}

class SAST::NamedParam is SAST::Param {

    method spit-gist {  ":$.sigil$.name" }
}

class SAST::Signature is SAST::Children {
    has SAST::PosParam @.pos;
    has SAST::NamedParam %.named;
    has $.has-invocant is rw;

    method stage2 ($) {
        for @!pos.kv -> $i,$p is rw {
            $p.ord = $i;
            $p.signature = self;
            $p .= do-stage2(tAny);
        }
        $_ .= do-stage2(tAny) for %!named.values;
        self;
    }

    method children { |@!pos,|%.named.values }
    method gist{ self.children».gist.join(', ') }
    method type { tAny }
    method clone(|c) {
        callwith(|c,:@!pos,:%!named);
    }

    method spit-gist {
        ~ @.children.map({ "{.type.name} {.spit-gist}" }).join(", ");
    }

}

class SAST::ClassDeclaration does SAST::Declarable is SAST::Children {
    has Spit::Type $.class is required;
    has SAST $.block is rw;

    method symbol-type { CLASS }
    method name { self.class.^name }
    method type { tAny }
    method children { ($!block // Empty),  }
    method stage2 ($) {
        $_ .= do-stage2(tAny) for self.children;
        self;
    }
}

class SAST::IntExpr is SAST::MutableChildren {
    has Str:D $.sym is required;

    method type { tInt }

    method stage2($) {
        $_ .= do-stage2(tInt,:desc("arguments to $!sym operation must be Ints")) for @.children;
        self;
    }

    method gist {
        $.node-name ~ "($!sym)" ~ $.gist-children;
    }
}

class SAST::Cmp is SAST::MutableChildren {
    has Str:D $.sym is required;

    method stage2($) {
        my $type = do given $!sym {
            when '=>'|'<='|'<'|'>'|'=='|'!=' { tInt }
            default { tStr }
        }
        $_ .= do-stage2($type,:desc("arguments to $!sym comparison must be {$type.^name}")) for @.children;
        self;
    }

    method type { tBool }
}

class SAST::EnumCmp is SAST::Children is rw {
    has SAST:D $.enum is required;
    has SAST:D $.check is required;

    method type { tBool }

    method children { $!enum,$!check }
}

class SAST::Increment is SAST::MutableChildren {
    has $.pre;
    has $.decrement = False;
    has $.amount = 1;

    method stage2($) {
        SX::Assignment-Readonly.new(match => self.match).throw if self[0].assign-type ~~ IMMUTABLE;
        @.children[0] .= do-stage2(tInt);
        self;
    }

    method type { tInt }

    method gist { $.node-name ~ "({$!decrement ?? '-' !! '+' }=$!amount)" ~ $.gist-children }
}

enum JunctionContext <NEVER-RETURN RETURN-WHEN-FALSE RETURN-WHEN-TRUE JUST-RETURN>;

# Represents the LHS or RHS of junctions where its value
# might need to returned as the value of the entire expression
# $.when it's True of False.
class SAST::CondReturn is SAST::Children  {
    has Bool:D $.when is required;
    has $.val is required;
    has $.Bool-call is rw;

    method stage2($ctx) {
        $!val .= do-stage2($ctx);
        if $!val.type !~~ tBool() {
            $!Bool-call = SAST::MethodCall.new(
                match => $!val.match,
                name => 'Bool',
                $!val.clone,
            ).do-stage2(tBool);
        }
        self;
    }

    method children { $!val,(self.stage3-done && $!Bool-call || Empty) }
    method type { $!val.type }
    method gist { $.node-name ~ "($!when)" ~ $.gist-children }
}

class SAST::Junction is SAST::MutableChildren {
    has $.dis; #disjunction(||) or conjunction(&&)
    has $.RHS-junct-ctx;
    has $.LHS-junct-ctx;

    method stage2 ($ctx,:$junct-ctx is copy) {
        # NEVER RETURN: We only care about it in Bool ctx -- never return its value.
        # JUST RETURN: We only care about its value.
        # RETURN-WHEN-TRUE: We care about its value when it's Bool ctx is True.
        # RETURN-WHEN-FALSE: The converse
        given $junct-ctx {
            when $ctx === tAny() {
                # Tell the LHS to be a Bool and pass on Any context to RHS.
                $!LHS-junct-ctx = NEVER-RETURN;
                $!RHS-junct-ctx = JUST-RETURN;
            }
            when NEVER-RETURN {
                $!LHS-junct-ctx = $!RHS-junct-ctx = NEVER-RETURN;
            }
            when { ! .defined or $_ == JUST-RETURN } {
                $!LHS-junct-ctx = $!dis ?? RETURN-WHEN-TRUE !! RETURN-WHEN-FALSE;
                $!RHS-junct-ctx = JUST-RETURN;
            }
            when RETURN-WHEN-TRUE  {
                if $!dis {
                    $!LHS-junct-ctx = RETURN-WHEN-TRUE;
                    $!RHS-junct-ctx = RETURN-WHEN-TRUE;
                } else {
                    $!LHS-junct-ctx = NEVER-RETURN;
                    $!RHS-junct-ctx = RETURN-WHEN-TRUE;
                }
            }
            when RETURN-WHEN-FALSE {
                if ! $!dis {
                    $!LHS-junct-ctx = RETURN-WHEN-FALSE;
                    $!RHS-junct-ctx = RETURN-WHEN-FALSE;
                } else {
                    $!LHS-junct-ctx = NEVER-RETURN;
                    $!RHS-junct-ctx = RETURN-WHEN-FALSE;
                }
            }
        }


        for flat @.children Z ($!LHS-junct-ctx,$!RHS-junct-ctx) <-> $child,$junct-ctx {
            if $child ~~ SAST::Junction {
                $child .= do-stage2($ctx,:$junct-ctx);
            } else {
                given $junct-ctx {
                    when NEVER-RETURN { $child .= do-stage2(tBool)  }
                    when JUST-RETURN  { $child .= do-stage2($ctx)   }
                    when RETURN-WHEN-TRUE {
                        $child = SAST::CondReturn.new(
                            when => True,
                            val => $child,
                            match => $child.match
                        ).do-stage2($ctx);
                    }
                    when RETURN-WHEN-FALSE {
                        $child = SAST::CondReturn.new(
                            when => False,
                            val => $child,
                            match => $child.match
                        ).do-stage2($ctx);
                    }
                }
            }
        }

        self;
    }

    method type {
        my @types = (self[0].type if $!LHS-junct-ctx !== NEVER-RETURN),
                    (self[1].type if $!RHS-junct-ctx !== NEVER-RETURN);
        if @types {
            derive-common-parent @types;
        } else {
            tBool;
        }
    }

    method gist { $.node-name ~ '(' ~ ($!dis ?? '||' !! '&&') ~ ')' ~ $.gist-children }
}

class SAST::Ternary is SAST::Children {
    has SAST:D $.cond is required;
    has SAST:D $.on-false is required;
    has SAST:D $.on-true is required;

    method type {
        derive-common-parent($!on-false.type,$!on-true.type);
    }

    method stage2($ctx) {
        $!cond .= do-stage2(tBool);
        $_ .= do-stage2($ctx) for $!on-true,$!on-false;
        self;
    }

    method children { $!cond,$!on-true,$!on-false }
}

class SAST::Pair is SAST::Children {
    has SAST:D $.key is required;
    has SAST:D $.value is required;

    method type { tAny() }
    method stage2($) {
        self.make-new(SX::NYI, feature => "Pairs as values").throw;
    }

    method children { $!key,$!value }
}

sub derive-common-parent(*@types) {
    my $cmp-to = @types.shift;
    for @types {
        $cmp-to = .^mro.first: { $cmp-to ~~ $_ }
    }
    return $cmp-to;
}

class SAST::List is SAST::MutableChildren {
    has $.type;
    method type {
        $!type ||= do {
            my $base-type = derive-common-parent @.children.map: { .type.&derive-type }
            tList($base-type);
        }
    }
    method elem-type { derive-type(self.type) }

    method stage2($) {
        $_ .= do-stage2(tStr) for @.children;
        self;
    }

    method compile-time {
        list do for @.children {
            return Nil unless .compile-time.defined;
            $_;
        }
    }
    method itemize { False }
}


role SAST::CompileTimeVal does SAST {
    method compile-time { $.val }
    method gist { $.node-name ~ "({$.val})" }
    method stage2 ($) { self }
}

class SAST::IVal does SAST::CompileTimeVal {
    has Int:D $.val is required is rw;
    method compile-time { $!val }
    method type { tInt }
}

class SAST::SVal does SAST::CompileTimeVal {
    has Str:D $.val is required is rw;
    method type { tStr }
    method compile-time { $!val }
}

class SAST::BVal does SAST::CompileTimeVal {
    has Bool:D $.val is required is rw;
    method type { tBool }
    method compile-time { $!val }
    # method stage2 ($ctx where { $_ ~~ tInt() }) {
    #     SAST::IVal.new(val => +$!val,:$.match).do-stage2($ctx);
    # }
}

class SAST::Concat is SAST::MutableChildren {
    method type { tStr }
    method gist { @.children».gist.join(' ~ ') }
    method compile-time {
        @.children.all.compile-time ?? @.children».compile-time.join !! Nil;
    }
    method stage2($) {
        $_ .= do-stage2(tStr) for @.children;
        self
    }
}

sub dollar_(Match :$match!,*%_) {
    SAST::MaybeReplace.new(
        name => '_',
        :$match,
        sigil => '$',
        :dont-depend,
        |%_,
    );
}

sub generate-topic-var(:$var! is rw,:$cond! is rw,:@blocks!) {
    if $cond.topic -> $topic-val {
        $var //= dollar_(match => $cond.match);
        $var.decl-type ||= $topic-val.type;
        $var .= do-stage2(tAny);
        $var.assign = $topic-val;
        .declare($var) for @blocks;
    } elsif $var {
        SX.new(message => "Invalid declaration of topic variable {$var.gist}. Condition has no topic.",node => $var).throw;
    }
}

class SAST::If is SAST::Children is rw {
    has SAST:D $.cond is required is rw;
    has SAST $.then is rw;
    has SAST $.else is rw;
    has SAST::VarDecl $.topic-var;
    has $.when;

    method stage2($ctx) is default {
        $!cond .= do-stage2(($!when ?? tAny() !! tBool()),:desc<If/unless condition>);
        if not $!when {
            generate-topic-var(
               var => $!topic-var,
               blocks => ($!then, ($!else if $!else ~~ SAST::Block:D)),
               :$!cond
            )
        }
        $_ .= do-stage2($ctx,:desc<if/unless block return value>) for $!then,($!else // Empty);
        self;
    }

    method children { $!cond,$!then,($!else // Empty),($!topic-var // Empty) }
    method type { derive-common-parent($!then.type, ($!else.type if $!else)) }
}

class SAST::While is SAST::Children {
    has SAST:D $.cond is required is rw;
    has SAST $.block is rw;
    has $.until;
    has SAST::VarDecl $.topic-var;

    method stage2($ctx) {
        $!cond .= do-stage2(tBool,:desc<while conditional>);
        generate-topic-var(var => $!topic-var,:$!cond,blocks => ($!block,));
        $!block .= do-stage2($ctx,:desc<while block return value>);
        self;
    }
    method children { $!cond,$!block,($!topic-var // Empty) }
    method type { tAny }
}

class SAST::Given is SAST::Children is rw {
    has SAST:D $.given is required;
    has SAST:D $.block is required;
    has SAST::VarDecl $.topic-var;

    method stage2($ctx) {
        $!topic-var = dollar_(match => $!given.match,assign => $!given,:dont-depend);
        $!topic-var .= do-stage2(tAny);
        $!block.declare($!topic-var);
        $!block .= do-stage2($ctx);
        self;
    }

    method children { $!block,$!topic-var }

    method type {$!block.type }
}

class SAST::For is SAST::Children {
    has SAST $.block is rw;
    has SAST:D $.list is required;
    has SAST::VarDecl $.iter-var;

    method stage2($ctx) {
        $!list .= do-stage2(tList);

        without $!iter-var {
            $_ = SAST::VarDecl.new(
                name => '_',
                match => $!list.match,
                sigil => '$',
                decl-type => $!list.elem-type,
                :dont-depend,
            );
        }
        $!iter-var.do-stage2(tAny);
        $!block.declare: $!iter-var;
        $!block .= do-stage2($ctx);
        self;
    }

    method children { $!list,$!block,$!iter-var }
    method type { $!block.type }
}

class SAST::Nop does SAST {
    method type { tAny }
    method stage2 ($) { self }
}

class SAST::Type does SAST {
    has Str $.class-name;
    has Spit::Type $.class-type;
    has @.params;
    has $!class-decl;

    method class-type {
        if not $!class-type {
            $!class-type = ($!class-decl = $*CURPAD.lookup(CLASS,$!class-name,:$.match)).class;
            $!class-type = $!class-type.^parameterize(|@!params.map(*.class)) if @!params;
        }
        $!class-type;
    }

    method ostensible-type { self.class-type }

    method stage2($ctx) {
        if self.class-type ~~ $ctx and $ctx.enum-type  {
            self;
        } elsif $ctx ~~ tStr() {
            SAST::SVal.new(val => self.class-type.^name,:$.match).do-stage2($ctx);
        } else {
            self;
        }
    }

    method type { self.class-type.enum-type ?? self.class-type !! tAny }
    method gist { $.node-name ~ "({$.class-name || $.class-type.name})" }
    method compile-time { self.class-type }
    method declaration { $!class-decl } # only here for Foo.WHY
}

class SAST::Blessed is SAST::MutableChildren is SAST::Type {

    method type { self.class-type }

    method stage2 ($ctx) {
        SX.new(node => self,
               message => "Can't bless something with type $.class-name because it doesn't have a primitive").throw
        unless self.type.primitive;

        if self.class-type.enum-type {
            self[0] .= do-stage2(tStr);
            if self[0].compile-time -> $str {
                if self.class-type.^lookup-by-str($str) -> $lookup {
                    SAST::Type.new(class-type => $lookup, match => self[0].match).do-stage2($ctx);
                } else {
                    SX.new(message => "'$str' is not part of the {self.class-type.name}").throw;
                }
            } else {
                SX.new(message => "Can't lookup a {self.class-type.name} with a runtime value").throw;
            }
        } else {
            self[0] .= do-stage2(self.type,:desc("didn't match primitive"));
            self;
        }

    }

    method compile-time { self[0].?compile-time }

    method gist { self.SAST::Type::gist ~  $.gist-children }
}

class SAST::Stmts is SAST::MutableChildren {
    method stage2($ctx) {
        $_ .= do-stage2(tAny) for @.children[^(*-1)];
        @.children[0] .= do-stage2($ctx);
        self;
    }

    method type { @.children[*-1] }
}

class SAST::Range is SAST::MutableChildren {
    has $.exclude-end;
    has $.exclude-start;
    method stage2($) {
        $_ .= do-stage2(tInt) for self.children;
        self;
    }

    method gist { $.node-name ~ "({'^' if $.exclude-start}..{'^' if $.exclude-end})" ~ $.gist-children }
    method type { tList(tInt) }

    method itemize { False }
}

class SAST::Accepts is SAST::MutableChildren {
    method type { tBool }
    method stage2($) {
        $_ .= do-stage2(tAny) for @.children;
        self;
    }
}

class SAST::WHAT is SAST::MutableChildren {
    method type { tStr() }
    method stage2($) {
        self[0] .= do-stage2(tAny);
        my $type = self[0].ostensible-type;
        SAST::SVal.new(val => $type.name,:$.match).do-stage2(tStr);
    }
}

class SAST::WHY is SAST::MutableChildren {
    method type { tStr() }

    method stage2($) {
        self[0] .= do-stage2(tAny);
        if self[0].?declaration -> {
            SAST::List.new(
                :$.match,
                |self[0].?declaration.docs.map({ SAST::SVal.new(val => .Str,match => .match)})
            ).do-stage2(tStr);
        } else {
            SX.new(message => "can't .WHY something that isn't declarable",:$.match).throw;
        }
    }
}

class SAST::Eval is SAST::Children   {
    has %.opts;
    has SAST::SVal:D $.src is required;
    has SAST::Block:D $.outer is required;

    method stage2($) {
        $!src .= do-stage2(tStr);
        $_ .= do-stage2(tAny) for %!opts.values;
        self
    }

    method type { tStr() }

    method children { $!src, }
}

sub make-rx($a){ rx/<$a>/ }
class SAST::Regex is SAST::Children is rw {
    has SAST:D $.src is required;
    has SAST %.patterns;

    method type { $.ctx ~~ tBool() ?? $.ctx !! tRegex() }
    method stage2($ctx){
        $!src .= do-stage2(tAny);
        if $ctx ~~ tBool() {
            self.stage2-node(
                SAST::CmpRegex,
                thing => SAST::Var.new(name => '_',:$.match,:sigil<$>).do-stage2(tAny),
                re => self,
            );
        } else {
            self;
        }
    }

    method children { $!src, }

    method compile-time {
        if $!src.compile-time -> $p5src {
            make-rx($p5src);
        }
    }
}

class SAST::CmpRegex is SAST::Children is rw {
    has SAST $.re;
    has SAST $.thing;

    method children { $!re,$!thing }

    method type { tBool }

    method stage2($)  {
        $!thing .= do-stage2(tStr);
        $!re .= do-stage2(tRegex);
        self;
    }
}

class SAST::FileContent is SAST::Children {
    has SAST:D $.file is required;

    method stage2($ctx) {
        $!file .= do-stage2(tStr);
        self;
    }
    method type { tList }
    method children { $!file,}
}

class SAST::Quietly is SAST::Children {
    has SAST:D $.block is required;
    has SAST $.null is rw;

    method stage2($ctx) {
        $!block .= do-stage2($ctx);
        $!null = $*SETTING.lookup(SCALAR,'*NULL')
                          .gen-reference(match => $!block.match)
                          .do-stage2(tFD);
        self;
    }

    method type { $!block.type }

    method children { $!block,$!null }
}

class SAST::Doom does SAST {
    has SX $.exception is required;

    method type { tAny }
}

class SAST::Itemize is SAST::MutableChildren {
    has Sigil:D $.sigil is required;

    method itemize { itemize-from-sigil($!sigil) }

    method stage2($ctx) {
        self[0] .= do-stage2(type-from-sigil($!sigil));
        self;
    }

    method gist { $.node-name ~ "($!sigil)" ~ $.gist-children }

    method type { self[0].type }
}
