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

require Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie;

my $flash = Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie->bake(
    {
        namespace   => 'editx_configure',
        code        => 'configuration_saved',
        ttl_seconds => 60,
    }
);

like( $flash->{id}, qr/\A[A-Za-z0-9_-]{20,96}\z/, 'flash id is URL-safe' );
is(
    $flash->{name},
    'editx_configure_flash_' . $flash->{id},
    'flash cookie name includes namespace and id'
);
like( $flash->{cookie}->as_string, qr/\Q$flash->{name}\E=configuration_saved/, 'flash cookie stores message code' );
like( $flash->{cookie}->as_string, qr/HttpOnly/, 'flash cookie is HttpOnly' );
like( $flash->{cookie}->as_string, qr/SameSite=Lax/, 'flash cookie uses SameSite=Lax' );

my $redirect_uri = Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie->uri_with_flash_id(
    '/cgi-bin/koha/plugins/run.pl?class=Plugin&method=configure',
    $flash->{id}
);
like( $redirect_uri, qr/[&]flash_id=\Q$flash->{id}\E\z/, 'flash id is appended to existing query string' );

my $redirect_uri_with_fragment = Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie->uri_with_flash_id(
    '/cgi-bin/koha/plugins/run.pl?class=Plugin&method=configure#ProductFormMappings',
    $flash->{id}
);
like( $redirect_uri_with_fragment, qr/[&]flash_id=\Q$flash->{id}\E#ProductFormMappings\z/, 'flash id is inserted before a redirect fragment' );

{
    local %ENV = (
        REQUEST_METHOD => 'GET',
        QUERY_STRING   => 'flash_id=' . $flash->{id},
        HTTP_COOKIE    => $flash->{name} . '=configuration_saved',
    );
    my $cgi      = CGI->new;
    my $consumed = Koha::Plugin::Fi::KohaSuomi::Editx::FlashCookie->consume(
        {
            cgi       => $cgi,
            namespace => 'editx_configure',
        }
    );

    is( $consumed->{code}, 'configuration_saved', 'consume returns message code' );
    like( $consumed->{cookie}->as_string, qr/\Q$flash->{name}\E=/, 'consume returns an expiring cookie' );
    like( $consumed->{cookie}->as_string, qr/expires=/, 'expiring cookie has an expires attribute' );
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
            code      => 'configuration_saved',
        }
    );

    like( $out, qr/Status: 303 See Other/, 'redirect uses 303 See Other' );
    like( $out, qr/Location: .*[&]flash_id=\Q$result->{id}\E/, 'redirect location includes generated flash id' );
    like( $out, qr/Set-Cookie: editx_configure_flash_\Q$result->{id}\E=configuration_saved/, 'redirect sets flash cookie' );
}

done_testing();
