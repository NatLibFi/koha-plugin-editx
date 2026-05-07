package Koha::Plugin::Fi::KohaSuomi::Editx::RuntimeLog;

use Modern::Perl;

use DateTime;
use Encode qw(decode);
use Fcntl qw(LOCK_EX);
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use Mojo::JSON qw(encode_json);
use Try::Tiny qw(catch try);

use C4::Context;
use Koha::DateUtils qw(dt_from_string);

use constant PLUGIN_CLASS       => 'Koha::Plugin::Fi::KohaSuomi::Editx';
use constant DEFAULT_LEVEL      => 'info';
use constant DEFAULT_MAX_BYTES  => 2_097_152;
use constant DEFAULT_TAIL_BYTES => 65_536;

my %LEVELS = (
    off    => -1,
    error  => 0,
    warn   => 1,
    info   => 2,
    notice => 3,
    debug  => 4,
);

sub levels {
    return [qw( off error warn info notice debug )];
}

sub runtime_log_dir {
    my $logdir = eval { C4::Context->config('logdir') };

    if ( defined $logdir
        && length $logdir
        && File::Spec->file_name_is_absolute($logdir)
        && $logdir !~ /__/
        && -d $logdir
        && -w $logdir )
    {
        return File::Spec->catdir( $logdir, 'editx' );
    }

    return File::Spec->catdir(
        C4::Context->temporary_directory,
        'koha-plugin-editx',
        'logs'
    );
}

sub path {
    return File::Spec->catfile(
        runtime_log_dir(),
        'editx-runtime.log'
    );
}

sub settings {
    my ( $class, $plugin_class ) = @_;

    $plugin_class ||= PLUGIN_CLASS;

    my $level = eval {
        C4::Context->dbh->selectrow_array(
            'SELECT plugin_value FROM plugin_data WHERE plugin_class = ? AND plugin_key = ?',
            undef,
            $plugin_class,
            'runtime_log_level'
        );
    };

    return {
        runtime_log_level => $class->normalize_level($level),
    };
}

sub should_log {
    my ( $class, $settings, $level ) = @_;

    $settings ||= $class->settings;

    my $configured = $class->normalize_level( $settings->{runtime_log_level} );
    return 0 if $configured eq 'off';

    $level = $class->normalize_level($level);
    return 0 if $level eq 'off';

    return $LEVELS{$level} <= $LEVELS{$configured};
}

sub log {
    my ( $class, $params ) = @_;

    $params ||= {};
    my $level = $class->normalize_level( $params->{level} );
    return 1 unless $class->should_log( $params->{settings}, $level );

    return try {
        my $path = $class->path;
        make_path( dirname($path) );

        open my $fh, '>>:encoding(UTF-8)', $path
            or die "Cannot open EDItX runtime log [$path]: $!";
        flock( $fh, LOCK_EX )
            or die "Cannot lock EDItX runtime log [$path]: $!";
        print {$fh} $class->format_line(
            {
                level     => $level,
                message   => $params->{message},
                component => $params->{component},
                context   => $params->{context},
            }
        );
        close $fh
            or die "Cannot close EDItX runtime log [$path]: $!";

        $class->_trim_file( $path, $params->{max_bytes} || DEFAULT_MAX_BYTES );
        1;
    }
    catch {
        warn "EDItX runtime logging failed: $_";
        return;
    };
}

sub tail {
    my ( $class, $max_bytes ) = @_;

    $max_bytes ||= DEFAULT_TAIL_BYTES;
    my $path = $class->path;
    return q{} unless -f $path;

    return try {
        open my $fh, '<:raw', $path
            or die "Cannot read EDItX runtime log [$path]: $!";
        my $size = -s $fh;
        my $offset = $size > $max_bytes ? $size - $max_bytes : 0;
        seek $fh, $offset, 0;
        my $data = q{};
        read $fh, $data, $max_bytes;
        close $fh;
        $data =~ s/\A[^\n]*\n// if $offset;
        return decode( 'UTF-8', $data );
    }
    catch {
        warn "EDItX runtime log tail failed: $_";
        return q{};
    };
}

sub format_line {
    my ( $class, $params ) = @_;

    $params ||= {};
    my $level = uc $class->normalize_level( $params->{level} );
    my $message = $class->_one_line( $params->{message} || q{} );
    my $context = ref $params->{context} eq 'HASH' ? { %{ $params->{context} } } : {};
    $context->{component} ||= $params->{component} if $params->{component};
    my $json = %{$context} ? q{ } . encode_json($context) : q{};
    my $dt = $class->_now;

    return sprintf '[%s %s] %s %s%s' . "\n",
        $class->_timestamp($dt),
        $class->_timezone_name($dt),
        $level,
        $message,
        $json;
}

sub normalize_level {
    my ( $class, $level ) = @_;

    $level = defined $level ? lc $level : DEFAULT_LEVEL;
    return exists $LEVELS{$level} ? $level : DEFAULT_LEVEL;
}

sub _now {
    my ($class) = @_;

    return eval { dt_from_string() }
        || DateTime->now( time_zone => 'local' );
}

sub _timestamp {
    my ( $class, $dt ) = @_;

    $dt ||= $class->_now;

    return $dt->ymd('-') . q{ } . $dt->hms(':');
}

sub _timezone_name {
    my ( $class, $dt ) = @_;

    $dt ||= $class->_now;

    my $tz = eval { C4::Context->tz };
    if ($tz) {
        my $short_name = eval {
            $tz->can('short_name_for_datetime')
                ? $tz->short_name_for_datetime($dt)
                : undef;
        };
        return $short_name
            if defined $short_name && length $short_name;

        my $name = eval { $tz->name };
        return $name
            if defined $name && length $name;
    }

    return 'local';
}

sub _one_line {
    my ( $class, $value ) = @_;

    $value =~ s/[\r\n]+/ /g;
    $value =~ s/\A\s+|\s+\z//g;

    return $value;
}

sub _trim_file {
    my ( $class, $path, $max_bytes ) = @_;

    return 1 unless $max_bytes && -f $path && -s $path > $max_bytes;

    open my $read_fh, '<:raw', $path
        or die "Cannot read EDItX runtime log [$path] for trim: $!";
    seek $read_fh, -$max_bytes, 2;
    my $tail = q{};
    read $read_fh, $tail, $max_bytes;
    close $read_fh;

    $tail =~ s/\A[^\n]*\n//;

    open my $write_fh, '>:raw', $path
        or die "Cannot trim EDItX runtime log [$path]: $!";
    print {$write_fh} $tail;
    close $write_fh
        or die "Cannot close trimmed EDItX runtime log [$path]: $!";

    return 1;
}

1;
