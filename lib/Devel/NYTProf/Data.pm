# vim: ts=8 sw=4 expandtab:
##########################################################
# This script is part of the Devel::NYTProf distribution
#
# Copyright, contact and other information can be found
# at the bottom of this file, or by going to:
# http://search.cpan.org/dist/Devel-NYTProf/
#
###########################################################
# $Id: Data.pm 1193 2010-04-21 13:41:34Z tim.bunce@gmail.com $
###########################################################
package Devel::NYTProf::Data;

=head1 NAME

Devel::NYTProf::Data - L<Devel::NYTProf> data loading and manipulation

=head1 SYNOPSIS

  use Devel::NYTProf::Data;

  $profile = Devel::NYTProf::Data->new( { filename => 'nytprof.out' } );

  $profile->dump_profile_data();

=head1 DESCRIPTION

Reads a profile data file written by L<Devel::NYTProf>, aggregates the
contents, and returns the results as a blessed data structure.

Access to the data should be via methods in this class to avoid breaking
encapsulation (and thus breaking your code when the data structures change in
future versions).

XXX Currently the documentation is out of date as this module is evolving
rapidly.

=head1 METHODS

=cut


use warnings;
use strict;

use Carp;
use Cwd qw(getcwd);
use Scalar::Util qw(blessed);

use Devel::NYTProf::Core;
use Devel::NYTProf::FileInfo;
use Devel::NYTProf::SubInfo;
use Devel::NYTProf::Util qw(make_path_strip_editor strip_prefix_from_paths get_abs_paths_alternation_regex);

our $VERSION = '3.11';

my $trace = (($ENV{NYTPROF}||'') =~ m/\b trace=(\d+) /x) && $1; # XXX a hack

=head2 new

  $profile = Devel::NYTProf::Data->new( );

  $profile = Devel::NYTProf::Data->new( {
    filename => 'nytprof.out', # default
    quiet    => 0,             # default, 1 to silence message
  } );

Reads the specified file containing profile data written by L<Devel::NYTProf>,
aggregates the contents, and returns the results as a blessed data structure.

=cut


sub new {
    my $class = shift;
    my $args = shift || { };

    my $file = $args->{filename} ||= 'nytprof.out';

    print "Reading $file\n" unless $args->{quiet};

    my $profile = load_profile_data_from_file(
        $file,
        $args->{callback},
    );

    return undef if $args->{callback};

    bless $profile => $class;

    my $fid_fileinfo = $profile->{fid_fileinfo};
    my $sub_subinfo  = $profile->{sub_subinfo};

    #warn _dumper($profile);

    # add profile ref so fidinfo & subinfo objects
    # XXX circular ref, add weaken
    $_ and $_->[7] = $profile for @$fid_fileinfo;
    $_->[7] = $profile for values %$sub_subinfo;

    # bless sub_subinfo data
    (my $sub_class = $class) =~ s/\w+$/SubInfo/;
    $_ and bless $_ => $sub_class for values %$sub_subinfo;

    # Where a given eval() has been invoked more than once
    # rollup the corresponding fids if they're "uninteresting".
    for my $fi ($profile->noneval_fileinfos) {
        $profile->collapse_evals_in($fi);
    }

    $profile->_clear_caches;

    # a hack for testing/debugging
    if (my $env = $ENV{NYTPROF_ONLOAD}) {
        my %onload = map { split /=/, $_, 2 } split /:/, $env, -1;
        warn _dumper($profile) if $onload{dump};
        exit $onload{exit}     if defined $onload{exit};
    }

    return $profile;
}


sub collapse_evals_in {
    my ($profile, $parent_fi) = @_;
    my $parent_fid = $parent_fi->fid;

    my %evals_on_line;
    for my $fi ($parent_fi->has_evals) {
        $profile->collapse_evals_in($fi); # recurse first
        push @{ $evals_on_line{$fi->eval_line} }, $fi;
    }
    while ( my ($line, $siblings) = each %evals_on_line) {

        next if @$siblings == 1;

        my @subs  = map { values %{ $_->subs } } @$siblings;
        my @calls = map { keys %{ $_->sub_call_lines } } @$siblings;
        my @evals = map { $_->has_evals(0) } @$siblings;
        my $msg = sprintf "%d:%d: multiple evals (subs %d, calls %d, evals %d, fids: %s)",
                $parent_fid, $line, scalar @subs, scalar @calls, scalar @evals,
                join(", ", map { $_->fid } @$siblings);
        warn "$msg\n" if $trace >= 3;

        next if @subs;  # ignore if the eval defines subs
        next if @evals; # ignore if the eval has nested evals

        # compare src code of evals and collapse identical ones
        my %src_same;
        for my $fi (@$siblings) {
            my $srclines_array = $fi->srclines_array || [];
            my $src = join "\n", @$srclines_array;
            my $key = join ",", # XXX just a basic key
                scalar @$srclines_array, # number of lines
                length $src,             # total length
                unpack("%32C*",$src);    # 32-bit checksum
            push @{$src_same{$key}}, $fi;
        }

        warn sprintf "%s COLLAPSING (%d evals with %d distinct srcs)\n",
                $msg, scalar @$siblings, scalar keys %src_same
            if $trace >= 1;

        # if not 'too many' distinct eval source strings then collapse
        # the evals for each distinct source string
        if (values %src_same < 100) {

            for my $src_same_fis (values %src_same) {
                next if @$src_same_fis == 1; # unique src code
                warn "Collapsing identical evals: @{[ map { $_->fid } @$src_same_fis ]}\n"
                    if $trace >= 3;
                my $fi = $parent_fi->collapse_sibling_evals(@$src_same_fis);
                @$src_same_fis = ( $fi ); # update list in-place
            }
        }
        else {
            $parent_fi->collapse_sibling_evals(@$siblings);
        }
    }
}

sub _caches       { return shift->{caches} ||= {} }
sub _clear_caches { return delete shift->{caches} }

sub attributes {
    return shift->{attribute} || {};
}

sub subname_subinfo_map {
    return { %{ shift->{sub_subinfo} } }; # shallow copy
}

# { pkgname => [ subinfo1, subinfo2, ... ], ... }
# if merged is true then array contains a single 'merged' subinfo
sub XXXpackage_subinfo_map {
    my $self = shift;
    my ($merged_subs, $nested_pkgs) = @_;

    my $all_subs = $self->subname_subinfo_map;
    my %pkg;
    while ( my ($name, $subinfo) = each %$all_subs ) {
        $name =~ s/^(.*::).*/$1/; # XXX $subinfo->package
        push @{ $pkg{$name} }, $subinfo;
    }
    if ($merged_subs) {
        while ( my ($pkg_name, $subinfos) = each %pkg ) {
            my $subinfo = shift(@$subinfos)->clone;
            $subinfo->merge_in($_) for @$subinfos;
            # replace the many with the one
            @$subinfos = ($subinfo);
        }
    }
    return \%pkg;
}

# package_tree_subinfo_map is like package_subinfo_map but returns
# nested data instead of flattened.
# for "Foo::Bar::Baz" package:
# { Foo => { '' => [...], '::Bar' => { ''=>[...], '::Baz'=>[...] } } }
# if merged is true then array contains a single 'merged' subinfo
sub package_subinfo_map {
    my $self = shift;
    my ($merge_subs, $nested_pkgs) = @_;

    my %pkg;
    my %to_merge;

    my $all_subs = $self->subname_subinfo_map;
    while ( my ($name, $subinfo) = each %$all_subs ) {
        $name =~ s/^(.*::).*/$1/; # XXX $subinfo->package
        my $subinfos;
        if ($nested_pkgs) {
            my @parts = split /::/, $name;
            my $node = $pkg{ shift @parts } ||= {};
            $node = $node->{ shift @parts } ||= {} while @parts;
            $subinfos = $node->{''} ||= [];
        }
        else {
            $subinfos = $pkg{$name} ||= [];
        }
        push @$subinfos, $subinfo;
        $to_merge{$subinfos} = $subinfos if $merge_subs;
    }

    for my $subinfos (values %to_merge) {
        my $subinfo = shift(@$subinfos)->clone;
        $subinfo->merge_in($_) for @$subinfos;
        # replace the many with the one
        @$subinfos = ($subinfo);
    }

    return \%pkg;
}

# [
#   undef,  # depth 0
#   {       # depth 1
#       "main::" => [ [ subinfo1, subinfo2 ] ],    # 2 subs in 1 pkg
#       "Foo::"  => [ [ subinfo3 ], [ subinfo4 ] ] # 2 subs in 2 pkg
#   }
#   {       # depth 2
#       "Foo::Bar::" => [ [ subinfo3 ] ]           # 1 sub in 1 pkg
#       "Foo::Baz::" => [ [ subinfo4 ] ]           # 1 sub in 1 pkg
#   }
# ]
sub packages_at_depth_subinfo {
    my $self = shift;
    my ($opts) = @_;

    my $merged = $opts->{merge_subinfos};
    my $all_pkgs = $self->package_subinfo_map($merged) || {};

    my @packages_at_depth = ({});
    while ( my ($fullpkgname, $subinfos) = each %$all_pkgs ) {

        $subinfos = [ grep { $_->calls } @$subinfos ]
            if not $opts->{include_unused_subs};

        next unless @$subinfos;

        my @parts = split /::/, $fullpkgname; # drops empty trailing part

        # accumulate @$subinfos for the full package name
        # and also for each succesive truncation of the package name
        for (my $depth; $depth = @parts; pop @parts) {
            my $pkgname = join('::', @parts, '');

            my $store = ($merged) ? $subinfos->[0] : $subinfos;

            # { "Foo::" => [ [sub1,sub2], [sub3,sub4] ] } # subs from 2 packages
            my $pkgdepthinfo = $packages_at_depth[$depth] ||= {};
            push @{ $pkgdepthinfo->{$pkgname} }, $store;

            last if not $opts->{rollup_packages};
        }
    }
    # fill in any undef holes at depths with no subs
    $_ ||= {} for @packages_at_depth;

    return \@packages_at_depth;
}

sub all_fileinfos {
    my @all = @{shift->{fid_fileinfo}};
    shift @all;    # drop fid 0
    # return all non-nullified fileinfos
    return grep { $_->fid } @all;
}

sub eval_fileinfos {
    return grep {  $_->eval_line } shift->all_fileinfos;
}

sub noneval_fileinfos {
    return grep { !$_->eval_line } shift->all_fileinfos;
}


sub fileinfo_of {
    my $self = shift;
    my $arg  = shift;
    if (not defined $arg) {
        carp "Can't resolve fid of undef value";
        return undef;
    }

    # check if already a file info object
    return $arg if ref $arg and UNIVERSAL::can($arg,'fid') and $arg->isa('Devel::NYTProf::FileInfo');

    my $fid = $self->resolve_fid($arg);
    if (not $fid) {
        carp "Can't resolve fid of '$arg'";
        return undef;
    }

    my $fi = $self->{fid_fileinfo}[$fid];
    return undef unless defined $fi->fid; # nullified?
    return $fi;
}


sub subinfo_of {
    my ($self, $subname) = @_;

    if (not defined $subname) {
        carp "Can't resolve subinfo of undef value";
        return undef;
    }

    my $si = $self->{sub_subinfo}{$subname}
        or warn carp "Can't resolve subinfo of '$subname'";

    return $si;
}


sub inc {

    # XXX should return inc from profile data, when it's there
    return @INC;
}

=head2 dump_profile_data

  $profile->dump_profile_data;
  $profile->dump_profile_data( {
      filehandle => \*STDOUT,
      separator  => "",
  } );

Writes the profile data in a reasonably human friendly format to the sepcified
C<filehandle> (default STDOUT).

For non-trivial profiles the output can be very large. As a guide, there'll be
at least one line of output for each line of code executed, plus one for each
place a subroutine was called from, plus one per subroutine.

The default format is a Data::Dumper style whitespace-indented tree.
The types of data present can depend on the options used when profiling.

If C<separator> is true then instead of whitespace, each item of data is
indented with the I<path> through the structure with C<separator> used to
separarate the elements of the path.
This format is especially useful for grep'ing and diff'ing.

=cut


sub dump_profile_data {
    my $self       = shift;
    my $args       = shift;
    my $separator  = $args->{separator} || '';
    my $filehandle = $args->{filehandle} || \*STDOUT;

    # shallow clone and add sub_caller for migration of tests
    my $startnode = $self;

    $self->_clear_caches;

    my $callback = sub {
        my ($path, $value) = @_;

        # not needed currently
        #if ($path->[0] eq 'attribute' && @$path == 1) { my %v = %$value; return ({}, \%v); }

        if (my $hook = $args->{skip_fileinfo_hook}) {

            # for fid_fileinfo elements...
            if ($path->[0] eq 'fid_fileinfo' && @$path==2) {
                my $fi = $value;

                # skip nullified fileinfo
                return undef unless $fi->fid;

                # don't dump internal details of lib modules
                return ({ skip_internal_details => scalar $hook->($fi, $path, $value) }, $value);
            }

            # skip sub_subinfo data for 'library modules'
            if ($path->[0] eq 'sub_subinfo' && @$path==2 && $value->[0]) {
                my $fi = $self->fileinfo_of($value->[0]);
                return undef if !$fi or $hook->($fi, $path, $value);
            }

            # skip fid_*_time data for 'library modules'
            if ($path->[0] =~ /^fid_\w+_time$/ && @$path==2) {
                my $fi = $self->fileinfo_of($path->[1]);
                return undef if !$fi or $hook->($fi, $path, $value);
            }
        }
        return ({}, $value);
    };

    _dump_elements($startnode, $separator, $filehandle, [], $callback);
}


sub _dump_elements {
    my ($r, $separator, $fh, $path, $callback) = @_;
    my $pad = "    ";
    my $padN;

    my $is_hash = (UNIVERSAL::isa($r, 'HASH'));
    my ($start, $end, $colon, $keys) =
          ($is_hash)
        ? ('{', '}', ' => ', [sort keys %$r])
        : ('[', ']', ': ', [0 .. @$r - 1]);

    if ($separator) {
        ($start, $end, $colon) = (undef, undef, $separator);
        $padN = join $separator, @$path, '';
    }
    else {
        $padN = $pad x (@$path + 1);
    }

    my $format = {sub_subinfo => {compact => 1},};

    print $fh "$start\n" if $start;
    my $key1 = $path->[0] || $keys->[0];
    for my $key (@$keys) {

        next if $key eq 'fid_srclines';

        my $value = ($is_hash) ? $r->{$key} : $r->[$key];

        # skip undef elements in array
        next if !$is_hash && !defined($value);
        # skip refs to empty arrays in array
        next if !$is_hash && ref $value eq 'ARRAY' && !@$value;

        my $dump_opts = {};
        if ($callback) {
            ($dump_opts, $value) = $callback->([ @$path, $key ], $value);
            next if not $dump_opts;
        }

        my $prefix = "$padN$key$colon";

        if (UNIVERSAL::can($value,'dump')) {
            $value->dump($separator, $fh, [ @$path, $key ], $prefix, $dump_opts);
        }
        else {

            # special case some common cases to be more compact:
            #		fid_*_time   [fid][line] = [N,N]
            #		sub_subinfo {subname} = [fid,startline,endline,calls,incl_time]
            my $as_compact = $format->{$key1}{compact};
            if (not defined $as_compact) {    # so guess...
                $as_compact =
                    (UNIVERSAL::isa($value, 'ARRAY') && @$value <= 9 && !grep { ref or !defined }
                        @$value);
            }
            $as_compact = 0 if not ref $value eq 'ARRAY';

            if ($as_compact) {
                no warnings qw(uninitialized);
                printf $fh "%s[ %s ]\n", $prefix, join(" ", map { defined($_) ? $_ : 'undef' } @$value);
            }
            elsif (ref $value) {
                _dump_elements($value, $separator, $fh, [ @$path, $key ], $callback);
            }
            else {
                print $fh "$prefix$value\n";
            }
        }
    }
    printf $fh "%s$end\n", ($pad x (@$path - 1)) if $end;
}


sub get_profile_levels {
    return shift->{profile_modes};
}

sub get_fid_line_data {
    my ($self, $level) = @_;
    $level ||= 'line';
    my $fid_line_data = $self->{"fid_${level}_time"};
    return $fid_line_data;
}


=head2 normalize_variables

  $profile->normalize_variables;

Traverses the profile data structure and normalizes highly variable data, such
as the time, in order that the data can more easily be compared. This is used,
for example, by the test suite.

The data normalized is:

=over

=item *

profile timing data: set to 0

=item *

subroutines: timings are set to 0

=item *

attributes, like basetime, xs_version, etc., are set to 0

=item *

filenames: path prefixes matching absolute paths in @INC are changed to "/.../"

=item *

filenames: eval sequence numbers, like "(re_eval 2)" are changed to 0

=back

=cut


sub normalize_variables {
    my $self       = shift;
    my $attributes = $self->attributes;

    for my $attr (qw(
        basetime xs_version perl_version clock_id ticks_per_sec nv_size
        profiler_duration profiler_end_time profiler_start_time
        total_stmts_duration total_stmts_measured total_stmts_discounted
        total_sub_calls
    )) {
        $attributes->{$attr} = 0;
    }

    for my $attr (qw(PL_perldb)) {
        delete $attributes->{$attr};
    }

    # normalize line data
    for my $level (qw(line block sub)) {
        my $fid_line_data = $self->get_fid_line_data($level) || [];

        # zero the statement timing data
        for my $of_fid (@$fid_line_data) {
            _zero_array_elem($of_fid, 0) if $of_fid;
        }
    }

    # zero sub info and sub caller times
    $_->normalize_for_test for values %{ $self->{sub_subinfo} };
    $_->normalize_for_test for $self->all_fileinfos;

    return;
}


sub _zero_array_elem {
    my ($ary_of_line_data, $index) = @_;
    for my $line_data (@$ary_of_line_data) {
        next unless $line_data;
        $line_data->[$index] = 0;

        # if line was a string eval
        # then recurse to zero the times within the eval lines
        if (my $eval_lines = $line_data->[2]) {
            _zero_array_elem($eval_lines, $index);    # recurse
        }
    }
}


sub _filename_to_fid {
    my $self = shift;
    my $caches = $self->_caches;
    return $caches->{_filename_to_fid_cache} ||= do {
        my $filename_to_fid = {};
        $filename_to_fid->{$_->filename} = $_->fid for $self->all_fileinfos;
        $filename_to_fid;
    };
}


=head2 subs_defined_in_file

  $subs_defined_hash = $profile->subs_defined_in_file( $file, $include_lines );

Returns a reference to a hash containing information about subroutines defined
in a source file.  The $file argument can be an integer file id (fid) or a file
path.

Returns undef if the profile contains no C<sub_subinfo> data for the $file.

The keys of the returned hash are fully qualified subroutine names and the
corresponding value is a hash reference containing L<Devel::NYTProf::SubInfo>
objects.

If $include_lines is true then the hash also contains integer keys
corresponding to the first line of the subroutine. The corresponding value is a
reference to an array. The array contains a hash ref for each of the
subroutines defined on that line, typically just one.

=cut

sub subs_defined_in_file {
    my ($self, $fid, $incl_lines) = @_;
    $fid = $self->resolve_fid($fid);
    $incl_lines ||= 0;
    $incl_lines = 0 if $fid == 0;
    my $caches = $self->_caches;

    my $cache_key = "subs_defined_in_file:$fid:$incl_lines";
    return $caches->{$cache_key} if $caches->{$cache_key};

    my $fi = $self->fileinfo_of($fid)
        or return;
    my %subs = %{ $fi->subs || {} }; # shallow copy

    if ($incl_lines) {    # add in the first-line-number keys
        croak "Can't include line numbers without a fid" unless $fid;
        for (values %subs) {
            next unless defined(my $first_line = $_->first_line);
            push @{$subs{$first_line}}, $_;
        }
    }

    $caches->{$cache_key} = \%subs;
    return $caches->{$cache_key};
}


=head2 subname_at_file_line

  @subname = $profile->subname_at_file_line($file, $line_number);
  $subname = $profile->subname_at_file_line($file, $line_number);

This method is currently unused and may be deprecated.

=cut


sub subname_at_file_line {
    my ($self, $fid, $line) = @_;

    my $subs = $self->subs_defined_in_file($fid, 0);

    # XXX could be done more efficiently
    my @subname;
    for my $sub_info (values %$subs) {
        next
            if $sub_info->first_line > $line
            or $sub_info->last_line < $line;
        push @subname, $sub_info->subname;
    }
    @subname = sort { length($a) <=> length($b) } @subname;
    return @subname if wantarray;
    carp
        "Multiple subs at $fid line $line (@subname) but subname_at_file_line called in scalar context"
        if @subname > 1;
    return $subname[0];
}


=head2 file_line_range_of_subme

  ($file, $fid, $first, $last) = $profile->file_line_range_of_sub("main::foo");

Returns the filename, fid, and first and last line numbers for the specified
subroutine (which must be fully qualified with a package name).

Returns an empty list if the subroutine name is not in the profile data.

The $fid return is the 'original' fid associated with the file the subroutine was created in.

The $file returned is the source file that defined the subroutine.

Where is a subroutine is defined within a string eval, for example, the fid
will be the pseudo-fid for the eval, and the $file will be the filename that
executed the eval.

Subroutines that are implemented in XS have a line range of 0,0 and currently
don't have an associated file.

=cut


sub file_line_range_of_sub {
    my ($self, $sub) = @_;

    my $sub_subinfo = $self->subinfo_of($sub)
        or return;    # no such sub
    my ($fid, $first, $last) = @$sub_subinfo;

    return if not $fid; # sub has no known file

    my $fileinfo = $fid && $self->fileinfo_of($fid)
        or die "No fid_fileinfo for sub $sub fid '$fid'\n";

    return ($fileinfo->filename, $fid, $first, $last, $fileinfo);
}


=head2 resolve_fid

  $fid = $profile->resolve_fid( $file );

Returns the integer I<file id> that corresponds to $file.

If $file can't be found and $file looks like a positive integer then it's
presumed to already be a fid and is returned. This is used to enable other
methods to work with fid or file arguments.

If $file can't be found but it uniquely matches the suffix of one of the files
then that corresponding fid is returned.

=cut


sub resolve_fid {
    my ($self, $file) = @_;
    Carp::confess("No file specified") unless defined $file;
    my $resolve_fid_cache = $self->_filename_to_fid;

    # exact match
    return $resolve_fid_cache->{$file}
        if exists $resolve_fid_cache->{$file};

    # looks like a fid already
    return $file
        if $file =~ m/^\d+$/;

    # XXX hack needed to because of how _map_new_to_old deals
    # with .pmc files because of how ::Reporter works
    return $self->resolve_fid($file) if $file =~ s/\.pmc$/.pm/;

    # unfound absolute path, so we're sure we won't find it
    return undef    # XXX carp?
        if $file =~ m/^\//;

    # prepend '/' and grep for trailing matches - if just one then use that
    my $match = qr{/\Q$file\E$};
    my @matches = grep {m/$match/} keys %$resolve_fid_cache;
    return $self->resolve_fid($matches[0])
        if @matches == 1;
    carp "Can't resolve '$file' to a unique file id (matches @matches)"
        if @matches >= 2;

    return undef;
}


sub package_fids {
    my ($self, $package) = @_;
    my @fids;
    #warn "package_fids '$package'";
    return @fids if wantarray;
    warn "Package 'package' has items defined in multiple fids: @fids\n"
        if @fids > 1;
    return $fids[0];
}


sub _dumper {
    require Data::Dumper;
    local $Data::Dumper::Sortkeys = 1;
    local $Data::Dumper::Indent = 1;
    return Data::Dumper::Dumper(@_);
}

1;

__END__

=head1 PROFILE DATA STRUTURE

XXX

=head1 LIMITATION

There's currently no way to merge profile data from multiple files.

=head1 SEE ALSO

L<Devel::NYTProf>

=head1 AUTHOR

B<Adam Kaplan>, C<< <akaplan at nytimes.com> >>
B<Tim Bunce>, L<http://www.tim.bunce.name> and L<http://blog.timbunce.org>
B<Steve Peters>, C<< <steve at fisharerojo.org> >>

=head1 COPYRIGHT AND LICENSE

 Copyright (C) 2008 by Adam Kaplan and The New York Times Company.
 Copyright (C) 2008,2009 by Tim Bunce, Ireland.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut
