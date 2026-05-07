#!/usr/bin/perl

use Modern::Perl;

use FindBin qw($Bin);
use File::Spec;
use Test::More;

my $plugin_root = File::Spec->catdir( $Bin, '..' );

sub read_file {
    my ($relative_path) = @_;

    my $path = File::Spec->catfile( $plugin_root, split m{/}, $relative_path );
    open my $fh, '<:encoding(UTF-8)', $path or die "Cannot read $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    return $content;
}

my $plugin_pm = read_file('Koha/Plugin/Fi/KohaSuomi/Editx.pm');
my $configure = read_file('Koha/Plugin/Fi/KohaSuomi/Editx/configure.tt');
my $tool = read_file('Koha/Plugin/Fi/KohaSuomi/Editx/tool.tt');
my $breadcrumbs = read_file('Koha/Plugin/Fi/KohaSuomi/Editx/includes/editx_breadcrumbs.inc');

like( $plugin_pm, qr{sub\s+tool\s*\{}, 'Plugin exposes a Koha tool page' );
like( $plugin_pm, qr{\$method\s*\|\|=\s*'tool'}, 'Plugin method URL defaults to the tool page' );
like( $plugin_pm, qr{tool_href\s*=>\s*\$self->plugin_method_url\('tool'\)}, 'Configure template receives tool_href' );
like( $plugin_pm, qr{manual_run_available}, 'Tool template receives manual action availability context' );

like( $breadcrumbs, qr{href="\[%\s*tool_href\s*\|\s*html\s*%\]">EDItX plugin</a>}, 'Breadcrumb plugin root points to the tool page' );
like( $breadcrumbs, qr{active_method\s*!=\s*'configure'}, 'Breadcrumb configure shortcut is hidden on the configure page' );
like( $breadcrumbs, qr{href="\[%\s*configure_href\s*\|\s*html\s*%\]">Configure</a>}, 'Breadcrumb includes a configure shortcut on operational pages' );

unlike( $configure, qr{run_sync_now}, 'Configure page has no manual sync action input' );
unlike( $configure, qr{Download and import now}, 'Configure page has no manual download/import button' );
unlike( $configure, qr{Manual run result}, 'Configure page has no manual run result block' );
like( $configure, qr{href="\[%\s*tool_href\s*\|\s*html\s*%\]">Cancel</a>}, 'Configure cancel returns to the tool page' );

like( $tool, qr{active_text='Operations'\s+active_method='tool'}, 'Tool page marks the Operations breadcrumb active' );
like( $tool, qr{\[%\s+USE\s+raw\s+%\]}, 'Tool page loads Koha raw plugin before using template filters' );
like( $tool, qr{name="run_sync_now"\s+value="1"}, 'Tool page exposes the manual sync POST action' );
like( $tool, qr{Download and import now}, 'Tool page has the manual download/import button' );
like( $tool, qr{Manual run result}, 'Tool page renders manual run results' );
like( $tool, qr{nightly_sync_enabled}, 'Tool page shows read-only nightly automation status' );
like( $tool, qr{href="\[%\s*configure_href\s*\|\s*html\s*%\]">Configure</a>}, 'Tool page links to configuration' );

done_testing();
