#!/usr/bin/perl

use Modern::Perl;

use FindBin qw($Bin);
use File::Spec;
use Test::More;

my $plugin_root = File::Spec->catdir( $Bin, '..' );
my @core_candidates = (
    File::Spec->catdir( $plugin_root, '..', '..', 'Koha' ),
    File::Spec->catdir( $ENV{HOME} || q{}, 'git', 'koha', 'Koha' ),
    File::Spec->catdir( $ENV{HOME} || q{}, 'git', 'KohaCommunity' ),
    File::Spec->catdir( $ENV{HOME} || q{}, 'git', 'Koha' ),
);
my ($core_root) = grep { -d $_ } @core_candidates;

unshift @INC, $plugin_root;
unshift @INC, $core_root if $core_root;

use CGI;

my $flash_class = 'Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie';
require Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie;

sub cookie_string {
    my ($cookie) = @_;

    return ref($cookie) && $cookie->can('as_string') ? $cookie->as_string : $cookie;
}

sub cookie_value {
    my ( $cookie, $name ) = @_;

    my $string = cookie_string($cookie);
    $string =~ /\Q$name\E=([^;]*)/ or die "Cannot find cookie value for $name";

    return $1;
}

sub consume_cookie {
    my ( $name, $value, %params ) = @_;

    local %ENV = (
        REQUEST_METHOD => 'GET',
        HTTP_COOKIE    => "$name=$value",
    );
    my $cgi = CGI->new;

    return $flash_class->consume(
        {
            cgi => $cgi,
            %params,
        }
    );
}

subtest 'constructor and cookie scope' => sub {
    my $flash = $flash_class->new(
        {
            namespace   => 'editx_configure',
            ttl_seconds => 60,
        }
    );
    $flash->success('EDItX plugin configuration saved.');
    my $baked = $flash->bake;

    is( $baked->{name}, 'editx_configure_flash', 'flash cookie uses a stable namespace-derived name' );
    like( cookie_string( $baked->{cookie} ), qr/\Q$baked->{name}\E=[A-Za-z0-9_-]+/, 'cookie stores a packed payload' );
    unlike( cookie_string( $baked->{cookie} ), qr/EDItX plugin configuration saved|configuration_saved/, 'cookie does not store plain text or message codes' );
    like( cookie_string( $baked->{cookie} ), qr/HttpOnly/, 'cookie is HttpOnly' );
    like( cookie_string( $baked->{cookie} ), qr/SameSite=Lax/, 'cookie uses SameSite=Lax' );
    unlike( cookie_string( $baked->{cookie} ), qr/(?:^|;\s*)path=/i, 'helper does not invent a default path' );

    eval { $flash_class->new };
    like( $@, qr/namespace is required/, 'namespace is required' );

    my $scoped = $flash_class->new(
        {
            namespace => 'editx_configure',
            path      => '/cgi-bin/koha/plugins/',
        }
    );
    $scoped->success('EDItX plugin configuration saved.');
    like( cookie_string( $scoped->bake->{cookie} ), qr/Path=\/cgi-bin\/koha\/plugins\//, 'explicit path is used when provided' );

    eval {
        $flash_class->new(
            {
                namespace => 'editx_configure',
                path      => '/cgi-bin/koha/plugins/;bad',
            }
        );
    };
    like( $@, qr/Invalid flash cookie path/, 'invalid explicit paths are rejected' );
};

subtest 'message normalization' => sub {
    my $warning = $flash_class->message( warn => 'Check this.' );
    is_deeply(
        $warning,
        {
            type        => 'warning',
            alert_class => 'warning',
            role        => 'alert',
            text        => 'Check this.',
            details     => [],
        },
        'warn alias normalizes to a warning message'
    );

    my $danger = $flash_class->message(
        danger => 'Failed.',
        details => [ ' First detail. ', undef, q{}, 'Second detail.' ],
    );
    is( $danger->{type},        'error',  'danger alias normalizes to semantic error type' );
    is( $danger->{alert_class}, 'danger', 'error type maps to Bootstrap danger class' );
    is( $danger->{role},        'alert',  'error messages use alert role' );
    is_deeply( $danger->{details}, [ 'First detail.', 'Second detail.' ], 'details are trimmed and empty values are skipped' );

    my $info = $flash_class->message( info => 'Visible info.' );
    is( $info->{role}, 'status', 'info messages use status role' );

    eval { $flash_class->message( debug => 'Nope.' ) };
    like( $@, qr/Invalid flash message type/, 'invalid message types are rejected' );

    eval { $flash_class->message( success => '   ' ) };
    like( $@, qr/text is required/, 'blank messages are rejected' );
};

subtest 'request queue and packed round trip' => sub {
    my $flash = $flash_class->new(
        {
            namespace    => 'editx_configure',
            path         => '/cgi-bin/koha/plugins/run.pl',
            max_messages => 2,
        }
    );
    $flash->success('EDItX plugin configuration saved.');
    $flash->error(
        'ProductForm mapping CSV import blocked.',
        details => [
            'Line 2 has no ONIX code.',
            'Line 3 repeats ONIX code ABC.',
        ],
    );
    $flash->info('This third message is trimmed by max_messages.');

    my $baked = $flash->bake;
    is( scalar @{ $baked->{messages} }, 2, 'bake keeps the configured maximum number of queued messages' );
    like( cookie_string( $baked->{cookie} ), qr/Path=\/cgi-bin\/koha\/plugins\/run[.]pl/, 'baked cookie keeps the configured path' );

    my $consumed = consume_cookie(
        $baked->{name},
        cookie_value( $baked->{cookie}, $baked->{name} ),
        namespace => 'editx_configure',
        path      => '/cgi-bin/koha/plugins/run.pl',
    );

    is( scalar @{ $consumed->{messages} }, 2, 'consume returns the packed queue' );
    is( $consumed->{messages}->[0]->{type}, 'success', 'first message keeps its type' );
    is( $consumed->{messages}->[1]->{type}, 'error', 'second message keeps its type' );
    is_deeply(
        $consumed->{messages}->[1]->{details},
        [
            'Line 2 has no ONIX code.',
            'Line 3 repeats ONIX code ABC.',
        ],
        'details survive the redirect'
    );
    like( cookie_string( $consumed->{cookie} ), qr/\Q$baked->{name}\E=/, 'consume returns an expiring cookie' );
    like( cookie_string( $consumed->{cookie} ), qr/expires=/, 'expiring cookie has an expires attribute' );
    like( cookie_string( $consumed->{cookie} ), qr/Path=\/cgi-bin\/koha\/plugins\/run[.]pl/, 'expiring cookie keeps the configured path' );
};

subtest 'empty and invalid payloads' => sub {
    my $empty = $flash_class->new( { namespace => 'editx_configure' } )->bake;
    is( $empty->{cookie}, undef, 'empty queues do not create flash cookies' );
    is_deeply( $empty->{messages}, [], 'empty queues still return an empty message list' );

    my $consumed = consume_cookie(
        'editx_configure_flash',
        'not-a-packed-payload',
        namespace => 'editx_configure',
    );
    is_deeply( $consumed->{messages}, [], 'invalid payload is ignored' );
    like( cookie_string( $consumed->{cookie} ), qr/editx_configure_flash=/, 'invalid payload is still expired' );
};

subtest 'redirect helper' => sub {
    local %ENV = ( REQUEST_METHOD => 'POST' );
    my $cgi = CGI->new;
    my $out = q{};
    open my $stdout, '>', \$out or die "Cannot redirect STDOUT to scalar: $!";
    local *STDOUT = $stdout;

    my $result = $flash_class->redirect_with_flash(
        {
            cgi       => $cgi,
            uri       => '/cgi-bin/koha/plugins/run.pl?class=Plugin&method=configure',
            namespace => 'editx_configure',
            messages  => [
                $flash_class->message( success => 'EDItX plugin configuration saved.' ),
                $flash_class->message( error   => 'ProductForm mapping CSV import blocked.' ),
            ],
        }
    );

    like( $out, qr/Status: 303 See Other/, 'redirect uses 303 See Other' );
    like( $out, qr/Location: \Q$result->{uri}\E/, 'redirect location stays on the clean configure URL' );
    unlike( $out, qr/flash_id=/, 'redirect location does not expose a flash id in the URL' );
    like( $out, qr/Set-Cookie: editx_configure_flash=[A-Za-z0-9_-]+/, 'redirect sets a packed flash cookie' );
    unlike( $out, qr/EDItX plugin configuration saved|ProductForm mapping CSV import blocked|configuration_saved/, 'redirect does not expose plain flash text or codes' );
};

done_testing();
