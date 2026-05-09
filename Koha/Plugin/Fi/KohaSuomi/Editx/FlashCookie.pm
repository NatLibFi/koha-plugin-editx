package Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie;

use Modern::Perl;

use CGI::Cookie;
use Digest::SHA qw(sha256_base64);

use constant DEFAULT_COOKIE_PATH => '/cgi-bin/koha/plugins/run.pl';
use constant DEFAULT_NAMESPACE   => 'plugin_flash';
use constant DEFAULT_TTL_SECONDS => 120;
use constant FLASH_ID_PARAM      => 'flash_id';

sub redirect_with_flash {
    my ( $class, $params ) = @_;

    $params ||= {};
    my $cgi = $params->{cgi} or die 'CGI object is required for flash redirect';
    my $uri = $params->{uri} or die 'Redirect URI is required for flash redirect';

    my $flash = $class->bake(
        {
            namespace   => $params->{namespace},
            code        => $params->{code},
            path        => $params->{path},
            ttl_seconds => $params->{ttl_seconds},
        }
    );
    my $redirect_uri = $class->uri_with_flash_id( $uri, $flash->{id}, $params->{param} );

    print $cgi->redirect(
        -uri    => $redirect_uri,
        -status => $params->{status} || '303 See Other',
        -cookie => $class->merge_cookies(
            $params->{cookies},
            $flash->{cookie},
        ),
    );

    return {
        id     => $flash->{id},
        name   => $flash->{name},
        uri    => $redirect_uri,
        cookie => $flash->{cookie},
    };
}

sub bake {
    my ( $class, $params ) = @_;

    $params ||= {};
    my $namespace = $class->_safe_namespace( $params->{namespace} );
    my $code      = $class->_safe_code( $params->{code} );
    my $id        = $class->_new_flash_id;
    my $ttl       = $class->_positive_int( $params->{ttl_seconds}, DEFAULT_TTL_SECONDS );

    return {
        id     => $id,
        name   => $class->_cookie_name( $namespace, $id ),
        cookie => $class->_cookie(
            {
                name    => $class->_cookie_name( $namespace, $id ),
                value   => $code,
                expires => '+' . $ttl . 's',
                path    => $params->{path},
            }
        ),
    };
}

sub consume {
    my ( $class, $params ) = @_;

    $params ||= {};
    my $cgi = $params->{cgi} or return {};

    my $id = scalar $cgi->param( $params->{param} || FLASH_ID_PARAM ) // q{};
    return {} unless $class->_valid_flash_id($id);

    my $namespace = $class->_safe_namespace( $params->{namespace} );
    my $name      = $class->_cookie_name( $namespace, $id );
    my $value     = scalar $cgi->cookie($name);
    return {} unless defined $value;

    my $result = {
        id     => $id,
        name   => $name,
        cookie => $class->expire_cookie(
            {
                namespace => $namespace,
                id        => $id,
                path      => $params->{path},
            }
        ),
    };

    $result->{code} = $value if $class->_valid_code($value);

    return $result;
}

sub expire_cookie {
    my ( $class, $params ) = @_;

    $params ||= {};
    my $namespace = $class->_safe_namespace( $params->{namespace} );
    my $id        = $params->{id} || q{};

    return unless $class->_valid_flash_id($id);

    return $class->_cookie(
        {
            name    => $class->_cookie_name( $namespace, $id ),
            value   => q{},
            expires => '-1d',
            path    => $params->{path},
        }
    );
}

sub uri_with_flash_id {
    my ( $class, $uri, $id, $param ) = @_;

    return $uri unless defined $uri && length $uri && $class->_valid_flash_id($id);

    $param ||= FLASH_ID_PARAM;
    my $separator = $uri =~ /\?/ ? '&' : '?';

    return $uri . $separator . $param . '=' . $id;
}

sub merge_cookies {
    my ( $class, @cookies ) = @_;

    my @merged;
    for my $cookie (@cookies) {
        next unless $cookie;
        if ( ref($cookie) eq 'ARRAY' ) {
            push @merged, grep { $_ } @{$cookie};
        } else {
            push @merged, $cookie;
        }
    }

    return unless @merged;
    return \@merged;
}

sub _cookie {
    my ( $class, $params ) = @_;

    my %cookie_params = (
        -name     => $params->{name},
        -value    => $params->{value},
        -path     => $params->{path} || DEFAULT_COOKIE_PATH,
        -expires  => $params->{expires},
        -httponly => 1,
        -samesite => 'Lax',
    );

    $cookie_params{-secure} = 1 if $class->_https_enabled;

    return CGI::Cookie->new(%cookie_params);
}

sub _cookie_name {
    my ( $class, $namespace, $id ) = @_;

    return join q{_}, $namespace, 'flash', $id;
}

sub _new_flash_id {
    my ($class) = @_;

    my $random = q{};
    if ( open my $fh, '<:raw', '/dev/urandom' ) {
        read $fh, $random, 32;
        close $fh;
    }

    $random .= join q{:}, time, rand(), $$, scalar localtime, {};

    my $id = sha256_base64($random);
    $id =~ tr{+/}{-_};
    $id =~ s/=+\z//;

    return $id;
}

sub _safe_namespace {
    my ( $class, $namespace ) = @_;

    $namespace = DEFAULT_NAMESPACE unless defined $namespace && length $namespace;
    die 'Invalid flash cookie namespace'
        unless $namespace =~ /\A[A-Za-z][A-Za-z0-9_]{0,40}\z/;

    return $namespace;
}

sub _safe_code {
    my ( $class, $code ) = @_;

    die 'Invalid flash cookie message code' unless $class->_valid_code($code);

    return $code;
}

sub _valid_code {
    my ( $class, $code ) = @_;

    return defined $code && $code =~ /\A[A-Za-z0-9_.:-]{1,80}\z/;
}

sub _valid_flash_id {
    my ( $class, $id ) = @_;

    return defined $id && $id =~ /\A[A-Za-z0-9_-]{20,96}\z/;
}

sub _positive_int {
    my ( $class, $value, $default ) = @_;

    return $default unless defined $value && $value =~ /\A[0-9]+\z/ && $value > 0;

    return int($value);
}

sub _https_enabled {
    return eval {
        require C4::Context;
        C4::Context->https_enabled ? 1 : 0;
    } ? 1 : 0;
}

1;
