use v6;

class PDF::Storage::Serializer {

    use PDF::Object;
    use PDF::Object::Array;
    use PDF::Object::Dict;
    use PDF::Object::Stream;
    use PDF::Object::Util :to-ast;
    use PDF::Writer;

    has Int $.size is rw = 1;  # first free object number
    has @.ind-objs;
    has %!obj-num-idx;
    has %.ref-count;
    has Bool $.renumber is rw = True;

    #| Reference count hashes. Could be derivate class of PDF::Object::Dict or PDF::Object::Stream.
    multi method analyse( Hash $dict! is rw) {
        return if %!ref-count{$dict.WHICH}++; # already encountered
        $.analyse($dict{$_}) for $dict.keys.sort;
    }

    #| Reference count arrays. Could be derivate class of PDF::Object::Array
    multi method analyse( Array $array! is rw ) {
        return if %!ref-count{$array.WHICH}++; # already encountered
        $.analyse($array[$_]) for $array.keys;
    }

    #| we don't reference count anything else at the moment.
    multi method analyse( $other! is rw ) is default {
    }

    #| prepare a set of objects for an incremental update. Only return indirect objects:
    #| - that have been fetched and updated, or
    #| - have been newly inserted (no object-number)
    #| of course, 
    multi method body( $reader, Bool :$updates! where $_, :$*compress ) {
        # only renumber new objects, starting from the highest input number + 1 (size)
        $.size = $reader.size;
        my $prev = $reader.prev;

        # disable auto-deref to keep all analysis and freeze stages lazy. We don't
        # need to consider or load anything that has not been already.
        temp $reader.auto-deref = False;

        # preserve existing object numbers. objects need to overwritten using the same
        # object and generation numbers
        temp $.renumber = False;
        %!ref-count = ();

        my @updated-objects = $reader.get-updates.list;
	@updated-objects.unshift: $reader.trailer;

        for @updated-objects -> $object {
            # reference count new objects
            $.analyse( $object );
        }

	for @updated-objects -> $object {
	    $.freeze( $object, :indirect )
	}

        my @objects = $.ind-objs.list;
	my subset TrailerIndObj of Pair where {.key eq 'ind-obj'
					       && .value[2] ~~ Pair
					       && .value[2].key eq 'dict'}

	my TrailerIndObj $trailer-ind-obj = @objects.shift; # first object is trailer dict
	my %dict = $trailer-ind-obj.value[2]<dict>.list;

        %dict<Prev> = :int($prev);
        %dict<Size> = :int($.size);

        return {
            :@objects,
            :trailer{ :%dict },
        }
    }

    #| rebuilds the body
    multi method body( PDF::Object :$Root!, :$compress) {
	$.body( PDF::Object.coerce({ :$Root }), :$compress );
    }
    multi method body( PDF::Object $trailer!, :$*compress) {

	temp $trailer.obj-num = 0;
	temp $trailer.gen-num = 0;

        %!ref-count = ();
        $.analyse( $trailer );
        $.freeze( $trailer, :indirect);
        my @objects = $.ind-objs.list;

	my subset TrailerIndObj of Pair where {.key eq 'ind-obj'
					       && .value[2] ~~ Pair
					       && .value[2].key eq 'dict'}

	my TrailerIndObj $trailer-ind-obj = @objects.shift; # first object is trailer dict
	my %dict = $trailer-ind-obj.value[2]<dict>.list;
        %dict<Size> = :int($.size);

        return %( :@objects, :trailer{ :%dict } );
    }

    method !get-ind-ref( Str :$id!) {
        :ind-ref( %!obj-num-idx{$id} )
            if %!obj-num-idx{$id}:exists;
    }

    #| construct a reverse index that unique maps unique $objects, identfied by .WHICH,
    #| to an object-number and generation-number. 
    method !index-object( Pair $ind-obj! is rw, Str :$id!, :$object) {
        my Int $obj-num = $object.obj-num 
	    if $object.can('obj-num');
        my Int $gen-num;
	my subset IsTrailer of UInt where 0;

        if $obj-num.defined && (($obj-num > 0 && ! $.renumber) || $obj-num ~~ IsTrailer) {
            # keep original object number
            $gen-num = $object.gen-num;
        }
        else {
            # renumber
            $obj-num = $!size++;
            $gen-num = 0;
        }

        my $ind-ref = [ $obj-num, $gen-num ];
        @.ind-objs.push: (:ind-obj[ $obj-num, $gen-num, $ind-obj]);
        %!obj-num-idx{$id} = $ind-ref;
        :$ind-ref;
    }

    method !freeze-dict( Hash $dict is rw) {
        my %frozen;
        %frozen{$_} = $.freeze( $dict{$_} )
            for $dict.keys.sort;
        %frozen;
    }

    method !freeze-array( Array $array is rw) {
        my @frozen;
        @frozen.push( $.freeze( $array[$_] ) )
            for $array.keys;
        @frozen;
    }

    #| should this be serialized as an indirect object?
    multi method is-indirect($ --> Bool) {*}

    #| streams always need to be indirect objects
    multi method is-indirect(PDF::Object::Stream $object)                 {True}

    #| avoid duplication of multiply referenced objects
    multi method is-indirect($, :$id! where {%!ref-count{$id} > 1})       {True}

    #| typed objects should be indirect, e.g. << /Type /Catalog .... >>
    multi method is-indirect(Hash $obj where PDF::Object.is-indirect-type($obj))  {True}

    #| presumably sourced as an indirect object, so output as such.
    multi method is-indirect($obj where { .can('obj-num') && .obj-num })  {True}

    #| allow anything else to inline
    multi method is-indirect($) is default                                {False}

    #| prepare and object for output.
    #| - if already encountered, return an indirect reference
    #| - produce an AST from the object content
    #| - determine if the object is indirect, if so index it,
    #|   generating or reusing the object-number in the process.
    proto method freeze(|) {*}

    #| handles PDF::Object::Dict, PDF::Object::Stream, (plain) Hash
    multi method freeze( Hash $object! is rw, Bool :$indirect) {
        my $id = ~$object.WHICH;

        # already an indirect object
        return self!"get-ind-ref"(:$id )
            if %!obj-num-idx{$id}:exists;

        my Bool $is-stream = $object.isa(PDF::Object::Stream);

        if $is-stream && $*compress.defined {
            $*compress ?? $object.compress !! $object.uncompress;
        }

        my $ind-obj;
        my $slot;

        if $is-stream {
            $ind-obj = :stream{
                :dict(Mu),
                :encoded($object.encoded),
            };
            $slot := $ind-obj.value<dict>;
        }
        else {
            $ind-obj = dict => Mu;
            $slot := $ind-obj.value;
        }

        # register prior to traversing the object. in case there are cyclical references
        my $ret = $indirect || $.is-indirect( $object, :$id )
            ?? self!"index-object"($ind-obj, :$id, :$object )
            !! $ind-obj;

        $slot = self!"freeze-dict"($object);

        $ret;
    }

    #| handles PDF::Object::Array, (plain) Array
    multi method freeze( Array $object! is rw, Bool :$indirect ) {
        my $id = ~$object.WHICH;

        # already an indirect object
        return self!"get-ind-ref"( :$id )
            if %!obj-num-idx{$id}:exists;

        my $ind-obj = array => Mu;
        my $slot := $ind-obj.value;

        # register prior to traversing the object. in case there are cyclical references
        my $ret = $indirect || $.is-indirect( $object, :$id )
            ?? self!"index-object"($ind-obj, :$id, :$object )
            !! $ind-obj;

        $slot = self!"freeze-array"($object);

        $ret;
    }

    #| handles other basic types
    multi method freeze($other) {
        to-ast $other;
    }

    #| do a full save to the named file
    multi method save-as(Str $file-name!,
			 PDF::Object $trailer-dict!,
                         Numeric :$version=1.3,
                         Str :$type='PDF',     #| e.g. 'PDF', 'FDF;
                         Bool :$compress,
        ) {
        my Hash $body = self.body($trailer-dict, :$compress );
        my Pair $ast = :pdf{ :header{ :$type, :$version }, :$body };
        my $writer = PDF::Writer.new( );
        $file-name ~~ m:i/'.json' $/
            ?? $file-name.IO.spurt( to-json( $ast ))
            !! $file-name.IO.spurt( $writer.write( $ast ), :enc<latin-1> );
    }
}
