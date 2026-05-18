#!/usr/bin/perl

use Modern::Perl;

use FindBin qw($Bin);
use File::Spec;
use Test::More;

my $plugin_root = File::Spec->catdir( $Bin, '..' );
my $plugin_pm   = read_file( File::Spec->catfile( $plugin_root, 'Koha', 'Plugin', 'Fi', 'KohaSuomi', 'Editx.pm' ) );
my $configure_template = read_file(
    File::Spec->catfile( $plugin_root, 'Koha', 'Plugin', 'Fi', 'KohaSuomi', 'Editx', 'configure.tt' )
);
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

require Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie;

sub read_file {
    my ($path) = @_;

    open my $fh, '<', $path or die "Cannot read $path: $!";
    local $/;
    return <$fh>;
}

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

my $flash = Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie->new(
    {
        namespace   => 'editx_configure',
        ttl_seconds => 60,
    }
);
$flash->success('EDItX plugin configuration saved.');

my $baked = $flash->bake;

is(
    $baked->{name},
    'editx_configure_flash',
    'flash cookie uses a stable configure cookie name'
);
like( cookie_string( $baked->{cookie} ), qr/\Q$baked->{name}\E=[A-Za-z0-9_-]+/, 'flash cookie stores a packed message payload' );
unlike( cookie_string( $baked->{cookie} ), qr/EDItX plugin configuration saved|configuration_saved/, 'flash cookie does not store a plain status code' );
like( cookie_string( $baked->{cookie} ), qr/HttpOnly/, 'flash cookie is HttpOnly' );
like( cookie_string( $baked->{cookie} ), qr/SameSite=Lax/, 'flash cookie uses SameSite=Lax' );
unlike( cookie_string( $baked->{cookie} ), qr/(?:^|;\s*)path=/i, 'flash cookie does not invent a default path' );

eval {
    Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie->new;
};
like( $@, qr/namespace is required/, 'flash cookie namespace is explicit' );

my $scoped_flash = Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie->new(
    {
        namespace => 'editx_configure',
        path      => '/cgi-bin/koha/plugins/',
    }
);
$scoped_flash->success('EDItX plugin configuration saved.');
my $scoped_baked = $scoped_flash->bake;
like( cookie_string( $scoped_baked->{cookie} ), qr/Path=\/cgi-bin\/koha\/plugins\//, 'flash cookie uses an explicit path when provided' );

eval {
    Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie->new(
        {
            namespace => 'editx_configure',
            path      => '/cgi-bin/koha/plugins/;bad',
        }
    );
};
like( $@, qr/Invalid flash cookie path/, 'flash cookie rejects invalid explicit paths' );

like(
    $plugin_pm,
    qr{CONFIGURE_FLASH_COOKIE_PATH\s*=>\s*'/cgi-bin/koha/plugins/run[.]pl'[\s\S]+?_configure_flash->consume[\s\S]+?messages\s*=>\s*\\\@messages[\s\S]+?sub _configure_flash \{[\s\S]+?FlashCookie->new[\s\S]+?namespace\s*=>\s*'editx_configure'[\s\S]+?path\s*=>\s*CONFIGURE_FLASH_COOKIE_PATH}s,
    'Configure flow scopes flash cookies to the plugin runner path'
);
like(
    $plugin_pm,
    qr{output_html\(\s*\$template->output\(\),\s*undef,\s*undef,\s*Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie->merge_cookies}s,
    'Configure page sends consumed flash cookies back as the output_html cookie argument'
);
unlike(
    $plugin_pm,
    qr{output_html\(\s*\$template->output\(\),\s*undef,\s*undef,\s*undef,\s*Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie->merge_cookies}s,
    'Configure page does not pass flash cookies as an ignored extra output_html argument'
);
like(
    $configure_template,
    qr{FOREACH message IN messages[\s\S]+?alert-\[% message[.]alert_class \| html %\][\s\S]+?role="\[% message[.]role \| html %\]"[\s\S]+?message[.]text \| html[\s\S]+?FOREACH detail IN message[.]details[\s\S]+?detail \| html},
    'Configure template renders queued flash message details'
);

my $multi_flash = Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie->new(
    {
        namespace => 'editx_configure',
    }
);
$multi_flash->success('EDItX plugin configuration saved.');
$multi_flash->error(
    'ProductForm mapping CSV import blocked.',
    details => [
        'Line 2 has no ONIX code.',
        'Line 3 repeats ONIX code ABC.',
    ],
);
my $multi_baked = $multi_flash->bake;

{
    local %ENV = (
        REQUEST_METHOD => 'GET',
        HTTP_COOKIE    => $multi_baked->{name} . '=' . cookie_value( $multi_baked->{cookie}, $multi_baked->{name} ),
    );
    my $cgi      = CGI->new;
    my $consumed = Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie->consume(
        {
            cgi       => $cgi,
            namespace => 'editx_configure',
        }
    );

    is( scalar @{ $consumed->{messages} }, 2, 'consume returns a queue of flash messages' );
    is( $consumed->{messages}->[0]->{type}, 'success', 'first message keeps its type' );
    is( $consumed->{messages}->[1]->{type}, 'error', 'second message keeps its semantic error type' );
    is( $consumed->{messages}->[1]->{alert_class}, 'danger', 'error messages render with the Bootstrap danger class' );
    is_deeply(
        $consumed->{messages}->[1]->{details},
        [
            'Line 2 has no ONIX code.',
            'Line 3 repeats ONIX code ABC.',
        ],
        'message details survive the redirect'
    );
    like( cookie_string( $consumed->{cookie} ), qr/\Q$multi_baked->{name}\E=/, 'consume returns an expiring cookie' );
    like( cookie_string( $consumed->{cookie} ), qr/expires=/, 'expiring cookie has an expires attribute' );
}

{
    local %ENV = (
        REQUEST_METHOD => 'GET',
        HTTP_COOKIE    => $multi_baked->{name} . '=not-a-packed-payload',
    );
    my $cgi      = CGI->new;
    my $consumed = Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie->consume(
        {
            cgi       => $cgi,
            namespace => 'editx_configure',
        }
    );

    is_deeply( $consumed->{messages}, [], 'invalid flash cookie payload is ignored' );
    like( cookie_string( $consumed->{cookie} ), qr/\Q$multi_baked->{name}\E=/, 'invalid flash cookie payload is still expired' );
}

{
    local %ENV = ( REQUEST_METHOD => 'POST' );
    my $cgi = CGI->new;
    my $out = q{};
    open my $stdout, '>', \$out or die "Cannot redirect STDOUT to scalar: $!";
    local *STDOUT = $stdout;

    my $result = Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie->redirect_with_flash(
        {
            cgi       => $cgi,
            uri       => '/cgi-bin/koha/plugins/run.pl?class=Plugin&method=configure',
            namespace => 'editx_configure',
            messages  => [
                Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie->message(
                    success => 'EDItX plugin configuration saved.'
                ),
            ],
        }
    );

    like( $out, qr/Status: 303 See Other/, 'redirect uses 303 See Other' );
    like( $out, qr/Location: \Q$result->{uri}\E/, 'redirect location stays on the clean configure URL' );
    unlike( $out, qr/flash_id=/, 'redirect location does not expose a flash id in the URL' );
    like( $out, qr/Set-Cookie: editx_configure_flash=[A-Za-z0-9_-]+/, 'redirect sets packed flash cookie' );
    unlike( $out, qr/EDItX plugin configuration saved|configuration_saved/, 'redirect does not expose plain flash text or codes' );
}

done_testing();
