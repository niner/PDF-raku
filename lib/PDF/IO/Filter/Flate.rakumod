use v6;

class PDF::IO::Filter::Flate {

    use PDF::IO::Filter::Predictors;
    use Compress::Zlib;
    use PDF::IO::Blob;
    use PDF::IO::Util;

    # Maintainer's Note: Flate is described in the PDF 32000 spec in section 7.4.4.
    # See also http://www.libpng.org/pub/png/book/chapter09.html - PNG predictors
    sub predictor-class {
        state $ = INIT PDF::IO::Util::have-pdf-native()
            ?? (require ::('PDF::Native::Filter::Predictors'))
            !! PDF::IO::Filter::Predictors;
    }

    multi method encode(Blob $_, :$Predictor, |c --> PDF::IO::Blob) is default {
        PDF::IO::Blob.new: compress($Predictor ?? predictor-class.encode( $_, :$Predictor, |c ) !! $_);
    }
    multi method encode(Str $_, |c) {
	$.encode( .encode('latin-1'), |c );
    }

    multi method decode(Blob $_, :$Predictor, |c --> PDF::IO::Blob) {
        PDF::IO::Blob.new: ($Predictor ?? predictor-class.decode( $_, :$Predictor, |c ) !! $_)
            given uncompress( $_ );
    }
    multi method decode(Str $_, |c) {
	$.decode( .encode('latin-1'), |c);
    }

}
