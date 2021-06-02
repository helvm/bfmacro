#! /usr/bin/perl 

# macro translator for bf 
# by Alva L. Couch,
#    Associate Prof. of Computer Science
#    Tufts University
# base macro language designed by Frans Faase, 
#    (http://http://home.planet.nl/~faase009/Ha_BF.html)
#  Copyright (C) 2005 by Alva L. Couch 
# 
#  This file is part of Bfmacro
#
#  Bfmacro is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2, or (at your option)
#  any later version.
#
#  Bfmacro is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with GNU CC; see the file COPYING.  If not, write to
#  the Free Software Foundation, 675 Mass Ave, Cambridge, MA 02139, USA.

# bfmacro synopsis: 
# input: modification of Frans Fasse's bf macro language 
# output: macro expansion commented with which macros are being expanded
# usage: bfmacro [options] file1.bfm file2.bfm ... > file.bf
#    -dump or -d: dump all definitions in human-readable form, as comments
#           in the output file. 
#    -nofaase or -nf: don't preload Frans Faase's macro set
#    -noannotate or -na: don't annotate code with comments describing 
#           macro boundaries; instead, prettyprint the output code. 
# note: when executed on a bf file rather than a bfm file, 
#       bfmacro file.bf # removes all whitespace from the file. 
#       bfmacro -na file.bf # prettyprints it. 

# supported syntax: 
#  builtins
#     to(X)    ! seek constant location  X, wherever that is
#     at(X)    ! re-anchor data pointer at X, assume it is there now. 
#              ! this is necessary after any unbalanced loop (e.g., [<])
#              ! before the next call to to(). If no loops are unbalanced, 
#              ! at(X) is unnecessary to use. 
#     plus(X)  ! add X +'s to output : called constant in Faase's language. 
#     minus(X) ! add X -'s to output : couch extension. 
#     right(X) ! add X >'s to output : couch extension. 
#     left(X)  ! add X <'s to output : couch extension. 
#  macro definition: 
#     mac(X,T) = definition including other macros ; 
#     couch modification: require ';' to close definition. 
#  constant definition 
#     X=16;    ! set X to refer to data[16]; undefined X's set automatically
#              ! to non-conflicting data cells. 
#     couch modification: require ';' to close definition. 
#  values of arguments: 
#     X        ! a defined constant
#     'A'      ! an ascii value : couch extension. 
#     24       ! a decimal value
#     0xaf     ! a hex value 
#  macro expansion
#     mac(W,Y) ! without following =, expands macro as token 
#  comments
#     ! this is a comment 
#  arguments to macros are interpreted as integers that 
#  identify unique cells in bf memory; mapping between variables
#  and memory locations is maintained by the macro-assembler. 
#  (constant locations are assigned starting at data[1] with addresses 
#  that increase in the order that variables are first mentioned) 

# syntax not supported: 
# - X+n = location n away from X

# to be done: 
# - integer expressions in variable assignments and arguments. 
# - documentation of macro preconditions and postconditions
#   (ideally self-reflexive) 
# - pragmas to assert post-conditions:
#   pragma reserve 2,39;  : reserve locations 2-39, don't bind to 
#     other variables (tunes auto-binding of to() arguments) 
# - autobinding only of values that are used as 'to' arguments
# - meta-macros: take code blocks as arguments 
#     repeat(times, block) : repeat a code block 'times' times. 
#     while( {block}, {block} ) : while block is true, do block 
#     for ({block},{block},{block},{block}) 
# - simple optimization: omit [-] first time at cell, omit >< and <>. 
# - improved scoping of to: currently [ to(X) > ] compiles and produces
#   incorrect result; should make this an error and require 
#   [ at(X) to(Y) > ] instead 

use strict; 
use Data::Dumper; 

#----------------
# option processing
#----------------

$main::opt_dump = &FALSE; 
$main::opt_annotate = &TRUE; 
$main::opt_faase = &TRUE; 

for (my $i=0; $i<@ARGV; ) { 
    if ($ARGV[$i] eq '-dump' or $ARGV[$i] eq '-d') { 
	$main::opt_dump=&TRUE; 
	splice(@ARGV,$i,1); 
    } elsif ($ARGV[$i] eq '-noannotate' or $ARGV[$i] eq '-na') { 
	$main::opt_annotate=&FALSE; 
	splice(@ARGV,$i,1); 
    } elsif ($ARGV[$i] eq '-nofaase' or $ARGV[$i] eq '-nf') { 
	$main::opt_faase=&FALSE; 
	splice(@ARGV,$i,1); 
    } elsif ($ARGV[$i] eq '-help' or $ARGV[$i] eq '-h') { 
	print STDERR "bfmacro usage: bfmacro [-dump] input.bfm >output.bf\n"; 
	print STDERR "  -dump or -d: dump all definitions into output as comments\n"; 
	print STDERR "  -noannotate or -na: don't add comments explaining expansions\n"; 
	print STDERR "  -nofaase or -nf: do not preload Faase's macro set\n"; 
	print STDERR "  -help or -h: provide help on usage\n"; 
	exit(1); 
    } else { 
	$i++; 
    } 
} 

# initialize parser variables 
my %builtins=('to'=>1,'at'=>1,'plus'=>1,'minus'=>1,'left'=>1,'right'=>1);
my %bindings = (); # name to value
my %bound    = (); # value to name 
my $count=1; 
my @tokens = (); 

#----------------
# read predefined macros 
#----------------
if ($main::opt_faase) { 
    my @frans; 
    while (<DATA>) { push(@frans, $_); } 
    my $frans = join('',@frans); 
    &tokenizer($frans,&FALSE); 
} 

#----------------
# read all files on command line 
#----------------
foreach my $f (@ARGV) { 
    open(FILE, "<$f") or die "can't read $f: $!"; 
    my @input = (<FILE>); # read all input
    close(FILE); 
    my $input = join('',@input); 
    &tokenizer($input,&TRUE); 
} 

#----------------
# tokenizer: do word-level and comment-level parsing; 
# discard invalid inputs
#----------------
sub tokenizer { 
    my $input = shift; 
    my $comment = shift; 
    my $context = ''; 
    my $inparen=0; 
    while ($input ne '') {
	if (! $inparen) { 
	    if ($input =~ s/^([\s\n]+)// ) { 
							       $context .= $1; 
	    } elsif ($input =~ s/^([a-zA-Z_][a-zA-Z0-9_]*)//) { 
		push(@tokens,new token('macro',$1,$1,
			      &contextBefore($context),
			      &contextAfter($input)));         $context .= $1; 
	    } elsif ($input =~ s/^(0x[0-9a-fA-F][0-9a-fA-F]*)//) { 
 	        my $hex = $1; my $val = eval($hex); 
		push(@tokens,new token('num',$hex,$val,
                              &contextBefore($context),
                              &contextAfter($input)));         $context .= $1; 
	    } elsif ($input =~ s/^([1-9][0-9]*|0)//) { 
		push(@tokens,new token('num',$1,$1,
                              &contextBefore($context),
                              &contextAfter($input)));         $context .= $1; 
	    } elsif ($input =~ s/^('[ -~]')//) { 
		my $char = $1; $char =~ s/^'//; $char =~ s/'$//; 
		push(@tokens,new token('num',$char,ord($char),
                              &contextBefore($context),
                              &contextAfter($input)));         $context .= $1; 
	    } elsif ($input =~ s/^([-+,.<>\[\]])//) { 
		push(@tokens,new token('opcode',$1,$1,
                              &contextBefore($context),
                              &contextAfter($input)));         $context .= $1; 
	    } elsif ($input =~ s/^(!.*)//) {
		push(@tokens,new token('comment',$1,$1,
			      &contextBefore($context),
                              &contextAfter($input)))
		    if $comment;  
							       $context .= $1; 
	    } elsif ($input =~ s/^(\()//) {
		push(@tokens,new token('lparen',$1,$1,
 			      &contextBefore($context),
			      &contextAfter($input)));         $context .= $1; 
		$inparen=1; 
	    } elsif ($input =~ s/^(=)//) {
		push(@tokens,new token('begindef',$1,$1,
			      &contextBefore($context),
			      &contextAfter($input))); 	       $context .= $1; 
	    } elsif ($input =~ s/^(;)//) {
		push(@tokens,new token('enddefin',$1,$1,
			      &contextBefore($context),
                              &contextAfter($input)));         $context .= $1; 
	    } elsif ($input =~ s/^(.)//) { 
		print STDERR "unknown character $1 in input!\n"; 
		print STDERR &context($context,$1,$input) . "\n"; 
							       $context .= $1; 
	    } else { 
		print STDERR "no match for '$input'; tokenizer error!\n";
		exit(1); 
	    }
	} else { 
	    if ($input =~ s/^([\s\n,]+)// ) { 
		# eat commas as well as whitespace
							       $context .= $1; 
	    } elsif ($input =~ s/^([a-zA-Z_][a-zA-Z0-9_]*)//) { 
		push(@tokens,new token('var',$1,$1,
                              &contextBefore($context),
			      &contextAfter($input)));         $context .= $1; 
	    } elsif ($input =~ s/^(0x[0-9a-fA-F][0-9a-fA-F]*)//) { 
 	        my $hex = $1; my $val = eval($hex); 
		push(@tokens,new token('num',$hex,$val,
                              &contextBefore($context),
                              &contextAfter($input)));         $context .= $1; 
	    } elsif ($input =~ s/^([1-9][0-9]*|0)//) { 
		push(@tokens,new token('num',$1,$1,
			      &contextBefore($context),
			      &contextAfter($input)));         $context .= $1; 
	    } elsif ($input =~ s/^('[ -~]')//) { 
		my $char = $1; $char =~ s/^'//; $char =~ s/'$//; 
		push(@tokens,new token('num',"'$char'",ord($char),
			      &contextBefore($context),
			      &contextAfter($input))); 	       $context .= $1; 
	    } elsif ($input =~ s/^(!.*)//) {
		push(@tokens,new token('comment',$1,$1,
			      &contextBefore($context),
			      &contextAfter($input)))
		    if $comment;  
							       $context .= $1; 
	    } elsif ($input =~ s/^(\))//) {
		push(@tokens,new token('rparen',$1,$1,
			      &contextBefore($context),
			      &contextAfter($input)));         $context .= $1; 
		$inparen=0; 
	    } elsif ($input =~ s/^(.)//) { 
		print STDERR "unknown character $1 in input\n"; 
		print STDERR &context($context,$1,$input) . "\n"; 
							       $context .= $1; 
	    } else { 
		print STDERR "no match for '$input'; tokenizer error!\n";
		exit(1); 
	    }
	} 
    } 
} 

#----------------
# reduction: collect arguments for macros; file macros separately!
#----------------
my $currentmac = undef; 
my $errors = undef; 
our %macros = (); 
for (my $i=0; $i<@tokens; ) { 
   if ($tokens[$i]->name eq 'macro') { 
        my $macro = $tokens[$i]; 
        my $name = $macro->string; 
        my $varspace = []; $macro->vars=$varspace; 
        $i++; 
	if ($tokens[$i]->name eq 'lparen') { 
	    # remove '('
	    splice (@tokens,$i,1); 
	    # parse out variable names 
	    while ($tokens[$i]->name eq 'var' 
	        || $tokens[$i]->name eq 'num'
                || $tokens[$i]->name eq 'comment') { 
		push(@$varspace,splice(@tokens,$i,1))
		    if $tokens[$i]->name eq 'var' 
		    || $tokens[$i]->name eq 'num'; 
	    } 
	    # check for ')'
	    if ($tokens[$i]->name ne 'rparen') { 
		 print STDERR "macro $name must end with ')'\n"; 
		 print STDERR &obcontext($tokens[$i]) . "\n"; 
		 $errors++; 
		 last; 
	    } 
	    # remove ')'
	    splice(@tokens,$i,1); 
	    $i--; # at macro 
	    if (defined $currentmac) { 
		push(@$currentmac,splice(@tokens,$i,1)); 
	    } else { $i++; } 
	} elsif ($tokens[$i]->name eq 'begindef') { 
	    $i--; 
	    my $name = $tokens[$i]->string; 
	    splice(@tokens,$i,1); # remove name
	    splice(@tokens,$i,1); # remove = 
	    if ($tokens[$i]->name ne 'num') { 
		print STDERR "Assignment '$name=' not followed by a number"
		     ." (".$tokens[$i]->name.")\n"; 
	        print STDERR &obcontext($tokens[$i]) . "\n"; 
		$errors++;
		last; 
	    } 
            my $val = $tokens[$i]->value; 
	    $bindings{$name} = $val; 	# name->value
	    $bound{$val} = $name; 	# loc->name
	    splice(@tokens,$i,1); # remove number
	    if ($tokens[$i]->name ne 'enddefin') { 
		print STDERR "Assignment of '$name' not followed by a ';'\n"; 
	        print STDERR &obcontext($tokens[$i]) . "\n"; 
		$errors++;
		last; 
	    } 
	    splice(@tokens,$i,1); # remove ';'
	} else { 
	    print STDERR "macro '$name' not followed by '(' or '='\n"; 
	    print STDERR &obcontext($tokens[$i]) . "\n"; 
	    $errors++;
	    last; 
        } 
   } elsif ($tokens[$i]->name eq 'begindef') { 	# define macro 
	if ($i>0 && $tokens[$i-1]->name eq 'macro') { 
	    splice(@tokens,$i,1); # remove begindef
	    if (defined $currentmac) { 
		$errors++; 	
		print STDERR "definition inside definition!\n"; 
	        print STDERR &obcontext($tokens[$i]) . "\n"; 
		last; 
	    } 
	    $currentmac = []; 
            $i--; # to macro definition 
	    $tokens[$i]->defn=$currentmac; 
            my $name = $tokens[$i]->string; 
	    if ($builtins{$name}) { 
		print STDERR "attempt to redefine builtin function '$name'!\n"; 
	        print STDERR &obcontext($tokens[$i]) . "\n"; 
		last; 
	    } elsif (! defined $macros{$name}) { 
		$macros{$name} = splice(@tokens,$i,1); 
	    } else { 
		print STDERR "attempt to redefine macro '$name'!\n"; 
	        print STDERR &obcontext($tokens[$i]) . "\n"; 
		last; 
	    } 
        } else { 
	    $errors++; 	
	    print STDERR "attempt to define non-macro!\n"; 
	    print STDERR &obcontext($tokens[$i]) . "\n"; 
	    last; 
	    
        } 
    } elsif ($tokens[$i]->name eq 'enddefin') { 
	if (! defined $currentmac) { 
	    $errors++; 	
	    print STDERR "end of definition not related to definition!\n"; 
	    print STDERR &obcontext($tokens[$i]) . "\n"; 
	    last; 
        } 
        $currentmac = undef; 
        splice(@tokens,$i,1); 
	
    } else { # other terms
	if (defined $currentmac) { 
	    push(@$currentmac,splice(@tokens,$i,1)); 
        } else { $i++; } 
    } 
} 
if (defined $currentmac) { 
    print STDERR "end of text during macro\n"; 
    $errors++; 
} 
if ($errors) { 
    print STDERR "errors encountered! exiting.\n"; 
    exit(1); 
} 

#----------------
# check macros for binding anomalies 
# including wrong number of arguments
# or unused or undeclared arguments
#----------------
my @macros = sort keys %macros; 
foreach my $m (@macros) { 
    my $desc = $macros{$m}; 
    my $vars = $desc->vars; my %vars = (); 
    foreach my $v (@$vars) { 
	if ($v->name ne 'var') { 
	    print STDERR "cannot use non-vars '".$v->string
		."' as macro arguments!\n"; 
	    print STDERR &obcontext($v) . "\n"; 
	    $errors++; 
	} 
	$vars{$v->string}++; 
    } 
    # read variable use in macros, flag all USED variables. 
    my $exps = $desc->defn; my %exps = (); 
    foreach my $e (@$exps) { 
	if ($e->name eq 'macro') { 
	    my $v2s = $e->vars; 
	    foreach my $v (@$v2s) { 
		if ($v->name eq 'var') { $exps{$v->string}++; } 
	    } 
        } 
    } 
    foreach my $k (sort keys %vars) {
	if (! $exps{$k}) { 
	    print STDERR "macro ".$desc->string.": argument $k unused\n";
	    print STDERR &obcontext($desc) . "\n"; 
	    $errors++; 
	}
    } 
    # may want these to default to global scope!
    foreach my $k (sort keys %exps) {
	if (! $vars{$k}) { 
	    print STDERR "macro $desc->string: unspecified argument $k\n";
	    print STDERR &obcontext($desc) . "\n"; 
	    $errors++; 
	}
    } 
} 
if ($errors) { 
    print STDERR "errors encountered! exiting.\n"; 
    exit(1); 
} 

#----------------
# print macro set in comments for documentation 
#----------------
if ($main::opt_dump) { 
    print "! ===== macros:  =====\n"; 
    foreach my $s (sort keys %macros) { 
	 print " ! ". &textit($macros{$s}); print "\n"; 
    } 
    print "! ===== tokens:  =====\n"; 
    foreach my $t (@tokens) { 
	if ($t->name eq 'macro' || $t->name eq 'opcode') { 
	    print " ! " . &textit($t) . "\n"; 
	} 
    } 
} 

#----------------
# trace usage of builtins, including 'to' 
#----------------
my $usage = {}; 
&trace_usage; 

foreach my $u (sort keys %$usage) { 
    if (! defined $bindings{$u}) {  # and $usage->{$u}->{'to'}) 
	while (defined $bound{$count}) { $count++; } 
	$bound{$count} = $u; 
	$bindings{$u} = $count++;
    } 
} 

#----------------
# check for invocation anomalies among tokens, 
# including wrong number of arguments and type botches
#----------------
foreach my $t (@tokens) { 
    &check_token($t); 
} 
if ($errors) { 
    print STDERR "errors encountered! exiting.\n"; 
    exit(1); 
} 

#----------------
# check for invocation anomalies among macros,
# including wrong number of arguments
#----------------
my $key; my $value; 
while (($key,$value) = each %macros) { 	# for each macro 
    foreach my $t (@{$value->defn}) {    # for each definition 
        &check_token($t); 
    } 
} 
if ($errors) { 
    print STDERR "errors encountered! exiting.\n"; 
    exit(1); 
} 

if ($main::opt_annotate) { 
    print "! ===== bindings: ====\n"; 
    foreach my $t (sort keys %bindings) { print " ! $t=$bindings{$t};\n"; } 
    print "! ===== code begins ==\n"; 
} 

#----------------
# with variable bindings in hand, and principle of invariance, 
# generate BF code matching macro definitions. This is a 
# single pass recursive substitution in which macros are expanded 
# all the way to terminals. 
#----------------
my $output = &generate; 
if ($errors) { 
    print STDERR "errors detected. Shutting down.\n"; 
    exit(1);
} 

#----------------
# done! print result! 
#----------------
print $output . "\n"; 

#----------------
# text handling
#----------------

# create a text representation of a token data structure 
sub textit { 
    my $thing = shift; 
    my $out = ''; 
    if ($thing->name eq 'macro') { 
	$out .= $thing->string; 
	$out .= "("; 
	if (defined $thing->vars) { 
	    my $first = 1; 
	    foreach my $t (@{$thing->vars}) { 
		if ($first) { $first=undef; } else { $out .= ","; } 
	        $out .= $t->string; 
	    } 
	    $out .= ")"; 
	} 
	if (defined $thing->defn) { 
	    $out .= " = "; 
	    foreach my $t (@{$thing->defn}) { 
	        $out .= &textit($t); 
	    } 
	    $out .= ";"; 
	} 
    } elsif ($thing->name eq 'opcode') { 
	$out .= $thing->string; 
    } 
    return $out; 
} 

# annotate a syntax tree with its labelling 
sub annotateit { 
    my $thing = shift; 
    my $out = ''; 
    if ($thing->name eq 'macro') { 
        my $name = $thing->name; 
        my $string = $thing->string; 
	$out .= "\n$name:$string";
	$out .= "("; 
	if (defined $thing->vars) { 
	    my $first = 1; 
	    foreach my $t (@{$thing->vars}) { 
		if ($first) { $first=undef; } else { $out .= ","; } 
		my $name = $t->name; 
		my $string = $t->string; 
	        $out .= "$name:$string"; 
	    } 
	    $out .= ")"; 
	} 
	if (defined $thing->defn) { 
	    $out .= " = "; 
	    foreach my $t (@{$thing->defn}) { 
	        $out .= &annotateit($t); 
	    } 
	    $out .= ";"; 
	} 
    } elsif ($thing->name eq 'opcode') { 
	$out .= $thing->string; 
    } 
    return $out; 
} 

#----------------
# debugging context printing 
#----------------

# very expensive routine to print context
# surrounding an error. Not for large programs!
sub context { 
    my $before = shift; 
    my $now = shift; 
    my $after = shift; 
    my $lines = shift; 
    my $out = &contextBefore($before,$lines)
            . '**here**>' . $now . '<**here**' 
            . &contextAfter($after,$lines) ; 
    return $out; 
} 

# compute 3 lines of context before a bug
sub contextBefore { 
    my $before = shift; 
    my $lines = shift; 
    $lines = 3 if ! defined $lines; 
    my @before = split(/\n/,$before); 
    splice(@before,0,@before-$lines);
    return join("\n",@before); 
} 

# compute three lines of context after a token
sub contextAfter { 
    my $after = shift; 
    my $lines = shift; 
    $lines = 3 if ! defined $lines; 
    my @after = split(/\n/,$after); 
    splice(@after,$lines);
    return join("\n",@after); 
} 

# construct a message about context
sub obcontext { 
    my $ob = shift; 
    my $lines = shift; 
    return $ob->before 
         . "**here**>" . $ob->string . "<**here**" 
         . $ob->after; 
} 

#----------------
# generate code from token stream 
#----------------
sub generate { 
    $main::d = 0; 
    $main::invariant = &TRUE; 
    $main::depth = 0; 
    my $output = ''; 
    @main::nest = (); # whether current level is nested
    @main::stack = (); 
    $main::depth = 0; 
    for (my $i=0; $i<@tokens; $i++) { 
	if ($tokens[$i]->name eq 'macro') {
	    $output .= "\n" if &needsCr($output) and $main::opt_annotate; 
	    $output .= &interpret($tokens[$i]); 
	} elsif ($tokens[$i]->name eq 'opcode') {
	    if (!$main::opt_annotate && ! &needsCr($output)) { 
		for (my $i=0; $i<$main::depth; $i++) { $output .= " "; } 
	    } 
            my $code = $tokens[$i]->string; 
	    if ($code eq '<') { $main::d--; } 
	    elsif ($code eq '>') { $main::d++; } 
	    elsif ($code eq '[') { 
	        $main::nested[$#main::nested]=1 if @main::nested;
	        push(@main::nested,0); 
	        push(@main::stack,$main::d); 
		if (! $main::opt_annotate) { 
		    $output .= "\n" if &needsCr($output);
		    for (my $i=0; $i<$main::depth; $i++) { $output .= " "; } 
		    $main::depth++; 
		} 
            } 
	    elsif ($code eq ']') { 
                my $nest = pop(@main::nested); 
	        my $d2 = pop(@main::stack); 
		if ($d2 != $main::d) { 
		    $main::invariant = &FALSE; 
	        } 
	        if (! $main::opt_annotate) { 
		    $main::depth--;
		    if ($nest) { 
			$output .= "\n" if &needsCr($output); 
			for (my $i=0; $i<$main::depth; $i++) { $output .= " "; } 
		    } 
	        } 
 	    } 
	    $output .= $code; 
	} elsif ($tokens[$i]->name eq 'comment') { 
	    $output .= "\n" if &needsCr($output); 
	    $output .= $tokens[$i]->string . "\n"; 
	} 
    }
    return $output; 
} 

#----------------
# interpret a macro recursively; expand to terminals
#----------------

sub interpret { 
    my $macro = shift; 
    # my $main::depth = shift; 
    my $name = $macro->string; 
    my $vars = $macro->vars; 
    my $out = ''; 
    if ($main::opt_annotate) { 
	# $out .= "\n" if &needsCr($out); 
	for (my $i=0; $i<$main::depth; $i++) { $out .= ' '; }
	$out .= "! " . &textit($macro) . "\n"; 
    } 
    # my $tokens = undef; 
    if ($name eq 'to') {
	if (! $main::invariant) { 
	    print STDERR "'to' encountered without positional invariance!\n"; 
	    print STDERR &obcontext($macro) . "\n"; 
	    $errors++; 
	    return; 
	} 
	my $var = $vars->[0]; # first variable wins
	if (! defined $var) {
	    print STDERR "to: no variable to seek!\n"; 
	    print STDERR &obcontext($macro) . "\n"; 
	    $errors++;
	} 
	my $loc; 
	if ($var->name eq 'var') { 
	    my $vname = $var->string; 
	    $loc = $bindings{$vname}; 
	} elsif ($var->name eq 'num') { 
	    $loc = $var->value; 
	} else { 
	    print STDERR "invalid operand type for 'to': ".$var->name."\n"; 
	    print STDERR &obcontext($macro) . "\n"; 
	    $errors++; 
	    return; 
	} 
	if ($main::d != $loc) {
	    if ($main::opt_annotate) { 
		$out .= "\n" if &needsCr($out); 
	        for (my $i=0; $i<$main::depth+1; $i++) { $out .= ' '; }
	    } else { 
		for (my $i=0; $i<$main::depth; $i++) { $output .= " "; } 
	    } 
	    while ($main::d>$loc) { $out .= '<'; $main::d--; } 
	    while ($main::d<$loc) { $out .= '>'; $main::d++; } 
	    if ($main::opt_annotate) { 
		$out .= "\n"; 
	    } 
	} 
    } elsif ($name eq 'at') {
	my $var = $vars->[0]; # first variable wins
	if (! defined $var) {
	    print STDERR "at: no position to assert!\n"; 
	    print STDERR &obcontext($macro) . "\n"; 
	    $errors++;
	} 
	my $loc; 
	if ($var->name eq 'var') { 
	    my $vname = $var->string; 
	    $loc = $bindings{$vname}; 
	} elsif ($var->name eq 'num') { 
	    $loc = $var->value; 
	} else { 
	    print STDERR "invalid operand type for 'to': ".$var->name."\n"; 
	    print STDERR &obcontext($macro) . "\n"; 
	    $errors++; 
	    return; 
	} 
	$main::d = $loc; $main::invariant = &TRUE; # now invariance assumption holds
	if ($main::opt_annotate) { 
	    $out .= "\n" if &needsCr($out); 
	    for (my $i=0; $i<$main::depth+1; $i++) { $out .= ' '; }
	    $out .= "! assert data pointer = $loc\n"; 
	    $out .= "\n"; 
	} 
    } elsif ($name eq 'plus') {
	my $var = $vars->[0]; # first variable wins
	if (! defined $var) {
	    print STDERR "'plus': no value to add!\n"; 
	    print STDERR &obcontext($macro) . "\n"; 
	    $errors++;
	    return; 
	} 
	my $loc; 
	if ($var->name eq 'var') { 
	    my $vname = $var->string; 
	    $loc = $bindings{$vname}; 
	} elsif ($var->name eq 'num') { 
	    $loc = $var->value; 
	} else { 
	    print STDERR "invalid operand type for 'plus': ".$var->name."\n"; 
	    print STDERR &obcontext($macro) . "\n"; 
	    $errors++; 
	} 
	if ($loc>0) { 
	    if ($main::opt_annotate) { 
		for (my $i=0; $i<$main::depth+1; $i++) { $out .= ' '; }
	    } 
	    if (!$main::opt_annotate && ! &needsCr($output)) { 
		for (my $i=0; $i<$main::depth; $i++) { $output .= " "; } 
	    } 
	    for (my $i=0; $i<$loc; $i++)  { $out .= '+'; } 
	    if ($main::opt_annotate) { 
		$out .= "\n"; 
	    } 
	} 
    } elsif ($name eq 'minus') {
	my $var = $vars->[0]; # first variable wins
	if (! defined $var) {
	    print STDERR "'minus': no value to subtract!\n"; 
	    print STDERR &obcontext($macro) . "\n"; 
	    $errors++;
	} 
	my $loc; 
	if ($var->name eq 'var') { 
	    my $vname = $var->string; 
	    $loc = $bindings{$vname}; 
	} elsif ($var->name eq 'num') { 
	    $loc = $var->value; 
	} else { 
	    print STDERR "invalid operand type for 'minus': ".$var->name."\n"; 
	    print STDERR &obcontext($macro) . "\n"; 
	    $errors++; 
	} 
	if ($loc>0) { 
	    if ($main::opt_annotate) { 
		$out .= "\n" if &needsCr($out); 
		for (my $i=0; $i<$main::depth+1; $i++) { $out .= ' '; }
	    } 
	    if (!$main::opt_annotate && ! &needsCr($output)) { 
		for (my $i=0; $i<$main::depth; $i++) { $output .= " "; } 
	    } 
	    for (my $i=0; $i<$loc; $i++)  { $out .= '-'; } 
	    if ($main::opt_annotate) { 
		$out .= "\n"; 
	    } 
	} 
    } elsif ($name eq 'left') {
	my $var = $vars->[0]; # first variable wins
	if (! defined $var) {
	    print STDERR "'left': no value to subtract!\n"; 
	    print STDERR &obcontext($macro) . "\n"; 
	    $errors++;
	} 
	my $loc; 
	if ($var->name eq 'var') { 
	    my $vname = $var->string; 
	    $loc = $bindings{$vname}; 
	} elsif ($var->name eq 'num') { 
	    $loc = $var->value; 
	} else { 
	    print STDERR "invalid operand type for 'left': ".$var->name."\n"; 
	    print STDERR &obcontext($macro) . "\n"; 
	    $errors++; 
	} 
	if ($loc>0) { 
	    if ($main::opt_annotate) { 
		$out .= "\n" if &needsCr($out); 
		for (my $i=0; $i<$main::depth+1; $i++) { $out .= ' '; }
	    } 
	    if (!$main::opt_annotate && ! &needsCr($output)) { 
		for (my $i=0; $i<$main::depth; $i++) { $output .= " "; } 
	    } 
	    for (my $i=0; $i<$loc; $i++)  { $out .= '<'; $main::d--; } 
	    if ($main::opt_annotate) { 
		$out .= "\n"; 
	    } 
	} 
    } elsif ($name eq 'right') {
	my $var = $vars->[0]; # first variable wins
	if (! defined $var) {
	    print STDERR "'right': no value to subtract!\n"; 
	    $errors++;
	} 
	my $loc; 
	if ($var->name eq 'var') { 
	    my $vname = $var->string; 
	    $loc = $bindings{$vname}; 
	} elsif ($var->name eq 'num') { 
	    $loc = $var->value; 
	} else { 
	    print STDERR "invalid operand type for 'right': ".$var->name."\n"; 
	    print STDERR &obcontext($macro) . "\n"; 
	    $errors++; 
	} 
	if ($loc>0) { 
	    if ($main::opt_annotate) { 
		$out .= "\n" if &needsCr($out); 
		for (my $i=0; $i<$main::depth+1; $i++) { $out .= ' '; }
	    } 
	    if (!$main::opt_annotate && ! &needsCr($output)) { 
		for (my $i=0; $i<$main::depth; $i++) { $output .= " "; } 
	    } 
	    for (my $i=0; $i<$loc; $i++)  { $out .= '>'; $main::d++; } 
	    if ($main::opt_annotate) { 
		$out .= "\n"; 
	    } 
	} 
    } else { 
	my $match = $macros{$name}; 
	if (! defined $match) { 
	    print STDERR "macro $name not defined!\n"; 
	    print STDERR &obcontext($macro) . "\n"; 
	    $errors++; 
	    return ''; 
	} 
	my $mvars = $match->vars; 
	if (scalar(@$mvars) != scalar(@$vars)) {
	    print STDERR "macro argument count incorrect!\n"; 
	    print STDERR &obcontext($macro) . "\n"; 
	    $errors++; 
	    return ''; 
	} 
	my %map = ();
	for (my $i=0; $i<@$vars; $i++) { 
	    $map{$mvars->[$i]->string}=$vars->[$i]; 
	} 
	# interpret macro by translating variables, 
	# and then recurse for further macros
	my $mdef = $match->defn; 
	foreach my $m (@$mdef) { 
	    if ($m->name eq 'opcode') { 
		if ($main::opt_annotate && ! &needsCr($out)) { 
		    for (my $i=0; $i<($main::depth+1); $i++) { $out .= " "; }
		} 
		my $code = $m->string; 
		if ($code eq '<') { $main::d--; } 
		elsif ($code eq '>') { $main::d++; } 
		elsif ($code eq '[') { 
		    $main::nested[$#main::nested]=1 if @main::nested; 
		    push(@main::nested,0); 
		    push(@main::stack,$main::d); 
		    if (! $main::opt_annotate) { 
			$out .= "\n" if &needsCr($out); 
			for (my $i=0; $i<$main::depth; $i++) { $out .= " "; } 
			$main::depth++; 
		    } 
                } 
		elsif ($code eq ']') { 
		    my $nest = pop(@main::nested); 
		    my $d2 = pop(@main::stack); 
		    if ($d2 != $main::d) { 
			$main::invariant = &FALSE; 
		    } 
		    if (! $main::opt_annotate) { 
			 $main::depth--;
			 if ($nest) { 
			     $out .= "\n" if &needsCr($out); 
			     for (my $i=0; $i<$main::depth; $i++) { $out .= " "; } 
			 } 
		    } 
		} 
		$out .= $m->string; 
	    } elsif ($m->name eq 'macro') {
		my $mac = $m->copy; 
		my $var = []; $mac->vars=$var; 
		foreach my $v (@{$m->vars}) { 
		    if ($v->name eq 'var') { 
			push(@$var, $map{$v->string}->copy); 
		    } else { 
			push(@$var, [@$v]); 
		    } 
		} 
	        if ($main::opt_annotate) { 
		    $out .= "\n" if &needsCr($out); 
		    $main::depth++; 
		} 
		$out .=&interpret($mac); 
	        if ($main::opt_annotate) { 
		    $main::depth--; 
		} 
	    } 
	} 
    } 
    $out .= "\n" if &needsCr($out) && $main::opt_annotate; 
    return $out; 
} 

#----------------
# do an ersatz macro expansion without generation, 
# tracing which macros get which variable values. 
#----------------
sub trace_usage { 
    for (my $i=0; $i<@tokens; $i++) { 
	if ($tokens[$i]->name eq 'macro') {
	    &trace_macro($tokens[$i]); 
	} 
    }
} 

#----------------
# trace one macro and determine contained calls
#----------------
sub trace_macro { 
    my $macro = shift; 
    my $depth = shift; 
    my $name = $macro->string; 
    my $vars = $macro->vars; 
    if ($name eq 'to'
     or $name eq 'at'
     or $name eq 'plus'
     or $name eq 'minus'
     or $name eq 'left'
     or $name eq 'right') {
	my $var = $vars->[0]; # first variable wins
	if (defined $var && $var->name eq 'var') { 
	    $usage->{$var->string}->{$name}++; 
	} 
    } else { 
	my $match = $macros{$name}; 
	if (! defined $match) { 
	    print STDERR "macro $name not defined!\n"; 
	    print STDERR &obcontext($macro) . "\n"; 
	    $errors++; 
	    return; 
	} 
	my $mvars = $match->vars; 
	if (scalar(@$mvars) != scalar(@$vars)) {
	    print STDERR "macro argument count incorrect!\n"; 
	    print STDERR &obcontext($macro) . "\n"; 
	    $errors++; 
	    return; 
	} 
	my %map = ();
	for (my $i=0; $i<@$vars; $i++) { 
	    $map{$mvars->[$i]->string}=$vars->[$i]; 
	    if ($vars->[$i]->name eq 'var') { 
		$usage->{$vars->[$i]->string}->{$name}++; 
	    } 
	} 
	# interpret macro by translating variables, 
	# and then recurse for further macros
	my $mdef = $match->defn; 
	foreach my $m (@$mdef) { 
	    if ($m->name eq 'macro') {
		my $mac = $m->copy; 
		my $var = []; $mac->vars=$var; 
		foreach my $v (@{$m->vars}) { 
		    if ($v->name eq 'var') { 
			push(@$var, $map{$v->string}->copy); 
		    } else { 
			push(@$var, [@$v]); 
		    } 
		} 
		&trace_macro($mac,$depth+1); 
	    } 
	} 
    } 
    return; 
} 

#----------------
# check arguments of token for correctness
#----------------
sub check_token { 
    my $t = shift; 
    if ($t->name eq 'macro') {
	my $name = $t->string; 
	my $args = scalar(@{$t->vars}); 
	if ($name eq 'to' 
	 or $name eq 'at' 
	 or $name eq 'plus' 
	 or $name eq 'minus' 
	 or $name eq 'left' 
	 or $name eq 'right') { 
	    if ($args != 1) {
		print STDERR "'$name' requires one argument!\n"; 
		print STDERR &obcontext($t) . "\n"; 
		$errors++; 
	    } 
	} else {
	    if (! defined $macros{$name}) {
		print STDERR "macro $name not defined!\n"; 
		print STDERR &obcontext($t) . "\n"; 
		$errors++; 
	    } 
	    my $margs = scalar(@{$macros{$name}->vars});
	    $margs = 0 if ! defined $margs; 
	    if ($margs != $args) {
		print STDERR "macro $name needs $margs arguments, has $args arguments!\n"; 
		print STDERR &obcontext($t) . "\n"; 
		$errors++; 
	    } 
	} 
    } 
} 

# logical constants
sub FALSE { undef } 
sub TRUE { 1 } 

# check whether a variable ends in a \n

sub endsWithCr { 
   return $_[0] =~ /\n$/; 
} 

sub needsCr { 
   return $_[0] !~ /\n$/; 
} 

package token; 

sub new { 
    my $pack = shift; 
    my $name = shift; 
    my $string = shift; 
    my $value = shift; 
    my $before = shift; 
    my $after = shift; 
    my $vars = shift; 
    my $defn = shift; 
    my $out = bless { 
	'name'   => $name, 
	'string' => $string, 
	'value'  => $value, 
	'before' => $before, 
	'after'  => $after
    } ; 
    $out->{'vars'} = $vars if defined $vars; 
    $out->{'defn'} = $defn if defined $defn; 
    return $out; 
} 

sub copy { 
   my $self = shift; 
   my $out = bless {}; 
   my $key; my $value; 
   while (($key,$value) = each %$self) { $out->{$key} = $value; } 
   return $out; 
} 

sub name   : lvalue { $_[0]->{'name'  } } 
sub string : lvalue { $_[0]->{'string'} } 
sub value  : lvalue { $_[0]->{'value' } } 
sub before : lvalue { $_[0]->{'before'} } 
sub after  : lvalue { $_[0]->{'after' } } 
sub vars   : lvalue { $_[0]->{'vars'  } } 
sub defn   : lvalue { $_[0]->{'defn'  } } 

package main; 

__DATA__

! builtins

! to(X)
! preconditions:  X is a non-negative integer; 
!                 no unbalanced loops encountered in the code so far, 
!                 or at(X) used after last unbalanced loop to anchor pointer. 
! postconditions: data pointer points to X 
! notes: Interpreter does not allow use of to(X) after an unbalanced loop
!        (e.g., [<]) unless there is an at(X) statement between the loop
!        and the to(X) in lexical scope. 

! at(X)
! preconditions:  X is a non-negative integer. 
! postconditions: presumes that data pointer is currently X, even if it is not, 
!                 for purposes of to(X). Essentially an 'origin' statement. 
! notes: One can use this to 'lie' about the data pointer, for the purposes of 
!        choosing a new 'origin' (0) for data. 

! plus(X)
! preconditions:  X is a non-negative integer. 
! postconditions: X +'s are appended to code. 
! notes: One can use ascii by enclosing in '', e.g. 'A'. 
!        One program for printing "hi" is 
!        zero(X) plus('h') . zero(X) plus('i') .

! minus(X)
! preconditions: X is a non-negative integer. 
! postconditions: X -'s are appended to the code. 

! left(X)
! preconditions: X is a non-negative integer. 
! postconditions: X <'s are appended to the code. 
! notes: tracks location; does not interfere with use of to(X)

! right(X)
! preconditions: X is a non-negative integer. 
! postconditions: X >'s are appended to the code. 
! notes: tracks location; does not interfere with use of to(X)

! number constructors

zero(X)  = to(X)[-] ; 
! preconditions:  X is a non-negative integer. 
! postconditions: pointer at X, data[X] is 0. 

one(X)   = to(X)[-]+ ; 
! preconditions:  X is a non-negative integer. 
! postconditions: pointer at X, data[X] is 1. 

inc(X)   = to(X)+ ; 
! preconditions:  X is a non-negative integer. 
! postconditions: pointer at X, data[X] is 1 greater than before. 

dec(X)   = to(X)- ; 
! preconditions:  X is a non-negative integer. 
! postconditions: pointer at X, data[X] is 1 less than before. 

set(X,Y) = zero(X) plus(Y) ; 
! preconditions:  X,Y are non-negative integers. 
! postconditions: pointer at X, data[X] is Y%256

! simple iteration 
for(X)   = to(X)[ ;
next(X)  = to(X)-] ; 
! usage: for(X) ...text... next(X)
! preconditions:  X is a non-negative integer. 
! postconditions: text is executed for decreasing values of X, not 
!                 including 0. 

! while 
while(X) = to(X)[ ;
wend(X)  = to(X)] ;
! usage: while(X) ...text... wend(X)
! preconditions:  X is a non-negative integer. 
! postconditions: text is executed while X remains non-zero. 

! moving and copying 
move(X,Y)      = for(X) to(Y) + next(X) ;
! preconditions:  X and Y are non-negative integers. 
! postconditions: data[Y]+=data[X]; data[X]=0.
! note: when unambiguous, I will identify each variable X with 
! a data location, writing Y+=X; X=0 instead of the above. 

move2(X,Y,Z)   = for(X) to(Y) + to(Z) + next(X) ; 
! preconditions:  X,Y,Z are non-negative integers. 
! postconditions: Y+=X; Z+=X; X=0; 

copy(S,D,T)    = move2(S,D,T) move(T,S) ;
! preconditions:  S,D,T are non-negative integers. 
! postconditions: D+=S; S+=T; T=0; 

! if-endif
if(X)          = to(X)[ ; 
endif(X)       = zero(X)] ; 
! usage: if(X) ...text... endif(X)
! preconditions:  X is non-negative integer
! postconditions: text between if and endif are executed if X != 0; X=0.

! if-then-else 
ifelse(X,T)    = one(T) if(X) zero(T) ; 
else(X,T)      = endif(X) if(T) ;
endifelse(X,T) = endif(T) to(X) ;
! usage: ifelse(X,T) ...text1... else(X,T) ...text2... endifelse(X,T)
! preconditions:  X is non-negative integer, text1 does not change T
! postconditions: if X is nonzero, text1 is executed, else text2 is executed.
!                 X=0, T=0

! logic 
tobool(S,D)    = zero(D) if(S) one(D) endif(S) ;
! preconditions: S and D are non-negative integers. 
! postconditions D=bool(S), 1 if S>0, 0 if S==0. 
! notes: consistently, I have erred on the side of simplicity; 
!        boolean functions are 1 and 0, as in C. 

not(S,D)       = one(D) if(S) zero(D) endif(S) ;
! preconditions:  S and D are non-negative integers. 
! postconditions: D=!S, 1 if S==0, 0 if S>0. 

or(S1,S2,D)    = zero(D) if(S1) one(D) endif(S1) if(S2) one(D) endif(S2) ; 
! preconditions:  S1,S2,S are non-negative integers 
! postconditions: D=S1 || S2; 0 if both are 0, 1 if either is nonzero. 
!                 S1=0, S2=0, d=S2.

and(S1,S2,D)   = zero(D) if(S1) tobool(S2,D) endif(S1) zero(S2) ; 
! preconditions:  S1,S2,S are non-negative integers 
! postconditions: D=S1 && S2; 0 if either is 0, 1 if both are nonzero. 
!                 S1=0, S2=0, d=S2

! comparison 
subtractMinimum(X1,X2,T1,T2,T3) =
  zero(T3) copy(X1,T1,T3) copy(X2,T2,T3) and(T1,T2,T3) to(T3)
  [ dec(X1) dec(X2)
    zero(T3) copy(X1,T1,T3) copy(X2,T2,T3) and(T1,T2,T3) to(T3)
  ] ;
! preconditions:  X1,X2,T1,T2,T3 are non-negative integers. 
!                 T1,T2 are 0. 
! postconditions: if X1>X2 then X1=X1-X2, X2=0, T1=T2=T3=0 
!                 if X1<X2 then X1=0, X2=X2-X1, T1=T2=T3=0 
!                 if X1==X2 then X1=X2=T1=T2=T3=0 

notEqual(x1,x2,d,t1,t2) = subtractMinimum(x1,x2,d,t1,t2) or(x1,x2,d); 
! preconditions:  x1,x2,d,t1,t2 are non-negative integers 
! postconditions: d=(x1!=x2); x1=x2=t1=t2=0

Equal(x1,x2,d,t1,t2) = notEqual(x1,x2,t1,d,t2) not(t1,d); 
! preconditions:  x1,x2,d,t1,t2 are non-negative integers 
! postconditions: d=(x1==x2); x1=x2=t1=t2=0

Greater(x1,x2,d,t1,t2) = subtractMinimum(x1,x2,d,t1,t2) zero(x2) move(x1,d); 
! preconditions:  x1,x2,d,t1,t2 are non-negative integers 
! postconditions: d=(x1>x2); x1=x2=t1=t2=0

Less(x1,x2,d,t1,t2) = subtractMinimum(x1,x2,d,t1,t2) zero(x1) move(x2,d); 
! preconditions:  x1,x2,d,t1,t2 are non-negative integers 
! postconditions: d=(x1<x2); x1=x2=t1=t2=0

GreaterOrEqual(x1,x2,d,t1,t2) = inc(x1) Greater(x1,x2,d,t1,t2); 
! preconditions:  x1,x2,d,t1,t2 are non-negative integers 
! postconditions: d=(x1>=x2); x1=x2=t1=t2=0

LessOrEqual(x1,x2,d,t1,t2) = inc(x2) Less(x1,x2,d,t1,t2); 
! preconditions:  x1,x2,d,t1,t2 are non-negative integers 
! postconditions: d=(x1<=x2); x1=x2=t1=t2=0

! multiplication 
times(s1,s2,d,t) = for(s1) copy(s2,d,t) next(s1) zero(s2); 
! preconditions:  s1,s2,d,t are non-negative integers 
! postconditions: d=s1*s2; s1=s2=t=0

! powers 
power(x,p,d,t1,t2) =
  to(d) +
  for(p)
    times(x,d,t1,t2)
    move(t1,d)
  next(p)
  zero(x); 
! preconditions: x,p,d,t1,t2 are non-negative integers 
! postconditions: d=x^p, x=p=t1=t2=0 

double(S,D) = move2(S,D,D); 
! preconditions: S,D are non-negative integers 
! postconditions: D+=S*S, S=0

! I/O
input(X) = to(X) , ; 
output(X) = to(X) . ; 

