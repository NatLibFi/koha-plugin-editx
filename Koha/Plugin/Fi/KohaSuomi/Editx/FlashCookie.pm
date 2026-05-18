package Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie;

use Modern::Perl;

use CGI::Util qw( expires );
use IO::Compress::Gzip qw( gzip );
use IO::Uncompress::Gunzip qw( gunzip );
use JSON qw( decode_json encode_json );
use MIME::Base64 qw( decode_base64 encode_base64 );

use constant DEFAULT_TTL_SECONDS       => 120;
use constant DEFAULT_MAX_MESSAGES      => 20;
use constant DEFAULT_MAX_TEXT_LENGTH   => 2048;
use constant DEFAULT_MAX_DETAILS       => 12;
use constant DEFAULT_MAX_DETAIL_LENGTH => 1024;
use constant DEFAULT_MAX_COOKIE_VALUE  => 3800;

=head1 NAME

Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie - cookie-backed flash message queue

=head1 SYNOPSIS

    my $flash = Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie->new(
        {
            namespace => 'editx_configure',
            path      => '/cgi-bin/koha/plugins/run.pl',
        }
    );

    $flash->success('Configuration saved.');
    $flash->error(
        'Worker check failed.',
        details => ['Restart the worker and save again.'],
    );
    $flash->redirect(
        {
            cgi => $cgi,
            uri => $self->plugin_method_url('configure'),
        }
    );

    my $flash = Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie->new(
        {
            namespace => 'editx_configure',
            path      => '/cgi-bin/koha/plugins/run.pl',
        }
    )->consume( { cgi => $cgi } );
    push @messages, @{ $flash->{messages} || [] };
    return $self->output_html(
        $template->output,
        undef,
        undef,
        Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie->merge_cookies(
            $self->{_auth_cookies},
            $flash->{cookie},
        )
    );

=head1 CONTRACT

Callers push ready-to-render semantic messages, not message codes. The helper
normalizes C<success>, C<info>, C<warning>, and C<error> into C<type>,
C<alert_class>, C<role>, C<text>, and C<details>. C<bake> serializes the queue
as JSON, compresses it with gzip, base64url-encodes it, and stores it in an
HTTP-only cookie. C<consume> returns normalized messages and an expiring cookie
for the same name/path. Templates must still escape C<text> and C<details>.

=cut

sub new {
    my ( $class, $params ) = @_;

    $params ||= {};
    my $path = $params->{path};
    if ( defined $path && length $path ) {
        die 'Invalid flash cookie path' unless $class->_valid_path($path);
    }

    return bless {
        namespace         => $class->_safe_namespace( $params->{namespace} ),
        path              => $path,
        ttl_seconds       => $class->_positive_int( $params->{ttl_seconds},      DEFAULT_TTL_SECONDS ),
        max_messages      => $class->_positive_int( $params->{max_messages},     DEFAULT_MAX_MESSAGES ),
        max_cookie_value  => $class->_positive_int( $params->{max_cookie_value}, DEFAULT_MAX_COOKIE_VALUE ),
        messages          => [],
    }, $class;
}

sub success {
    my ( $self, $text, %params ) = @_;

    return $self->add( success => $text, %params );
}

sub info {
    my ( $self, $text, %params ) = @_;

    return $self->add( info => $text, %params );
}

sub warning {
    my ( $self, $text, %params ) = @_;

    return $self->add( warning => $text, %params );
}

sub error {
    my ( $self, $text, %params ) = @_;

    return $self->add( error => $text, %params );
}

sub danger {
    my ( $self, $text, %params ) = @_;

    return $self->error( $text, %params );
}

sub add {
    my ( $self, $type, $text, %params ) = @_;

    CORE::push @{ $self->{messages} },
        $self->_normalize_message(
        {
            type    => $type,
            text    => $text,
            details => $params{details},
        }
        );

    $self->_limit_message_count;

    return $self;
}

sub push {
    my ( $self, @messages ) = @_;

    for my $message (@messages) {
        next unless $message;
        CORE::push @{ $self->{messages} }, $self->_normalize_message($message);
    }

    $self->_limit_message_count;

    return $self;
}

sub message {
    my ( $class, $type, $text, %params ) = @_;

    return $class->_normalize_message(
        {
            type    => $type,
            text    => $text,
            details => $params{details},
        }
    );
}

sub messages {
    my ($self) = @_;

    return [ @{ $self->{messages} } ];
}

sub bake {
    my ( $self, $params ) = @_;

    die 'FlashCookie->bake must be called on a FlashCookie object'
        unless ref $self;

    if ( $params && $params->{messages} ) {
        $self->push( @{ $params->{messages} } );
    }

    my $name = $self->_cookie_name;

    return {
        name     => $name,
        messages => $self->messages,
    } unless @{ $self->{messages} };

    my ( $value, $messages ) = $self->_packed_messages;

    return {
        name     => $name,
        messages => $messages,
        cookie   => $self->_cookie(
            {
                name    => $name,
                value   => $value,
                expires => '+' . $self->{ttl_seconds} . 's',
                path    => $self->{path},
            }
        ),
    };
}

sub consume {
    my ( $self, $params ) = @_;

    $self = $self->new($params) unless ref $self;
    $params ||= {};
    my $cgi = $params->{cgi} or return {};

    my $name  = $self->_cookie_name;
    my $value = scalar $cgi->cookie($name);
    return {} unless defined $value;

    return {
        name     => $name,
        messages => $self->_unpack_messages($value),
        cookie   => $self->expire_cookie,
    };
}

sub expire_cookie {
    my ( $self, $params ) = @_;

    $self = $self->new($params) unless ref $self;

    return $self->_cookie(
        {
            name    => $self->_cookie_name,
            value   => q{},
            expires => '-1d',
            path    => $self->{path},
        }
    );
}

sub redirect {
    my ( $self, $params ) = @_;

    $params ||= {};
    my $cgi = $params->{cgi} or die 'CGI object is required for flash redirect';
    my $uri = $params->{uri} or die 'Redirect URI is required for flash redirect';

    my $flash = $self->bake;

    print $cgi->redirect(
        -uri    => $uri,
        -status => $params->{status} || '303 See Other',
        -cookie => $self->merge_cookies(
            $params->{cookies},
            $flash->{cookie},
        ),
    );

    return {
        name     => $flash->{name},
        uri      => $uri,
        cookie   => $flash->{cookie},
        messages => $flash->{messages},
    };
}

sub redirect_with_flash {
    my ( $class, $params ) = @_;

    $params ||= {};
    my $flash = $class->new(
        {
            namespace        => $params->{namespace},
            path             => $params->{path},
            ttl_seconds      => $params->{ttl_seconds},
            max_messages     => $params->{max_messages},
            max_cookie_value => $params->{max_cookie_value},
        }
    );
    $flash->push( @{ $params->{messages} || [] } );

    return $flash->redirect($params);
}

sub merge_cookies {
    my ( $class, @cookies ) = @_;

    my @merged;
    for my $cookie (@cookies) {
        next unless $cookie;
        if ( ref($cookie) eq 'ARRAY' ) {
            CORE::push @merged, grep { $_ } @{$cookie};
        } else {
            CORE::push @merged, $cookie;
        }
    }

    return unless @merged;
    return \@merged;
}

sub _packed_messages {
    my ($self) = @_;

    my @messages = @{ $self->{messages} };
    my $value    = $self->_pack_payload( \@messages );
    return ( $value, \@messages ) if length($value) <= $self->{max_cookie_value};

    @messages = map {
        my %message = %{$_};
        delete $message{details};
        \%message;
    } @messages;
    $value = $self->_pack_payload( \@messages );
    return ( $value, \@messages ) if length($value) <= $self->{max_cookie_value};

    @messages = (
        $self->_normalize_message(
            {
                type => 'warning',
                text => 'Flash message details were too large to carry through the redirect.',
            }
        )
    );

    return ( $self->_pack_payload( \@messages ), \@messages );
}

sub _pack_payload {
    my ( $self, $messages ) = @_;

    my $json       = encode_json( { v => 1, messages => $messages } );
    my $compressed = q{};
    gzip \$json => \$compressed
        or die 'Could not compress flash cookie payload';

    return $self->_base64url_encode($compressed);
}

sub _unpack_messages {
    my ( $self, $value ) = @_;

    return [] unless defined $value && length $value;
    return [] unless $value =~ /\A[A-Za-z0-9_-]+\z/;

    my $compressed = eval { $self->_base64url_decode($value) };
    return [] if $@ || !defined $compressed;

    my $json = q{};
    return [] unless gunzip \$compressed => \$json;

    my $payload = eval { decode_json($json) };
    return [] if $@ || ref($payload) ne 'HASH';
    return [] unless ( $payload->{v} || 0 ) == 1 && ref( $payload->{messages} ) eq 'ARRAY';

    my @messages;
    for my $message ( @{ $payload->{messages} } ) {
        my $normalized = eval { $self->_normalize_message($message) };
        CORE::push @messages, $normalized if !$@ && $normalized;
    }

    return \@messages;
}

sub _normalize_message {
    my ( $class, $message ) = @_;

    die 'Flash message must be a hash reference'
        unless ref($message) eq 'HASH';

    my $type = $class->_normalize_type( $message->{type} );
    my $text = $class->_trim_text( $message->{text}, DEFAULT_MAX_TEXT_LENGTH );
    die 'Flash message text is required' unless length $text;

    my @details;
    if ( ref( $message->{details} ) eq 'ARRAY' ) {
        for my $detail ( @{ $message->{details} } ) {
            last if @details >= DEFAULT_MAX_DETAILS;
            my $text = $class->_trim_text( $detail, DEFAULT_MAX_DETAIL_LENGTH );
            CORE::push @details, $text if length $text;
        }
    }

    return {
        type        => $type,
        alert_class => $class->_alert_class($type),
        role        => $class->_role($type),
        text        => $text,
        details     => \@details,
    };
}

sub _normalize_type {
    my ( $class, $type ) = @_;

    my %types = (
        success => 'success',
        info    => 'info',
        warning => 'warning',
        warn    => 'warning',
        error   => 'error',
        danger  => 'error',
    );

    die 'Invalid flash message type'
        unless defined $type && $types{$type};

    return $types{$type};
}

sub _alert_class {
    my ( $class, $type ) = @_;

    return $type eq 'error' ? 'danger' : $type;
}

sub _role {
    my ( $class, $type ) = @_;

    return $type eq 'success' || $type eq 'info' ? 'status' : 'alert';
}

sub _trim_text {
    my ( $class, $text, $max_length ) = @_;

    return q{} unless defined $text;

    $text = "$text";
    $text =~ s/\A\s+//;
    $text =~ s/\s+\z//;

    return $text if length($text) <= $max_length;

    return substr( $text, 0, $max_length - 3 ) . '...';
}

sub _limit_message_count {
    my ($self) = @_;

    splice @{ $self->{messages} }, $self->{max_messages}
        if @{ $self->{messages} } > $self->{max_messages};

    return;
}

sub _base64url_encode {
    my ( $class, $value ) = @_;

    my $encoded = encode_base64( $value, q{} );
    $encoded =~ tr{+/}{-_};
    $encoded =~ s/=+\z//;

    return $encoded;
}

sub _base64url_decode {
    my ( $class, $value ) = @_;

    my $decoded = $value;
    $decoded =~ tr{-_}{+/};
    $decoded .= '=' x ( ( 4 - length($decoded) % 4 ) % 4 );

    return decode_base64($decoded);
}

sub _cookie {
    my ( $class, $params ) = @_;

    my @cookie_parts = ( $params->{name} . '=' . $params->{value} );

    if ( defined $params->{path} && length $params->{path} ) {
        die 'Invalid flash cookie path' unless $class->_valid_path( $params->{path} );
        CORE::push @cookie_parts, 'Path=' . $params->{path};
    }

    CORE::push @cookie_parts, 'expires=' . expires( $params->{expires}, 'cookie' )
        if defined $params->{expires} && length $params->{expires};
    CORE::push @cookie_parts, 'HttpOnly';
    CORE::push @cookie_parts, 'SameSite=Lax';
    CORE::push @cookie_parts, 'Secure' if $class->_https_enabled;

    return join '; ', @cookie_parts;
}

sub _cookie_name {
    my ($self) = @_;

    return $self->{namespace} . '_flash';
}

sub _safe_namespace {
    my ( $class, $namespace ) = @_;

    die 'Flash cookie namespace is required'
        unless defined $namespace && length $namespace;
    die 'Invalid flash cookie namespace'
        unless $namespace =~ /\A[A-Za-z][A-Za-z0-9_]{0,40}\z/;

    return $namespace;
}

sub _valid_path {
    my ( $class, $path ) = @_;

    return defined $path && $path =~ /\A[\x21-\x3A\x3C-\x7E]+\z/;
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
