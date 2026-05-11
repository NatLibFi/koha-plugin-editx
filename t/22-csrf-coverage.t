#!/usr/bin/perl

use Modern::Perl;

use FindBin qw($Bin);
use File::Find qw(find);
use File::Spec;
use Test::More;

my $plugin_root = File::Spec->catdir( $Bin, '..' );
$plugin_root = File::Spec->rel2abs($plugin_root);

sub read_file {
    my ($relative_path) = @_;

    my $path = File::Spec->catfile( $plugin_root, split m{/}, $relative_path );
    open my $fh, '<:encoding(UTF-8)', $path or die "Cannot read $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    return $content;
}

sub post_form_lines_missing_csrf {
    my ($content) = @_;

    my @lines = split /\n/, $content;
    my @missing;
    my ( $open_line, $found );
    my $line_number = 0;

    for my $line (@lines) {
        $line_number++;
        if ( !defined $open_line && $line =~ m{<form\b[^>]*\bmethod=(["'])post\1}i ) {
            $open_line = $line_number;
            $found     = 0;
        }

        $found = 1 if defined $open_line && $line =~ m{csrf-token\.inc};

        if ( defined $open_line && $line =~ m{</form\s*>}i ) {
            push @missing, $open_line unless $found;
            undef $open_line;
            $found = 0;
        }
    }

    push @missing, "$open_line (unclosed)" if defined $open_line;

    return @missing;
}

sub plugin_csrf_include_files {
    my $template_root = File::Spec->catdir( $plugin_root, qw(Koha Plugin Fi KohaSuomi Editx) );
    my @found;

    find(
        {
            no_chdir => 1,
            wanted   => sub {
                return unless -f $File::Find::name;
                return unless ( File::Spec->splitpath($File::Find::name) )[2] eq 'csrf-token.inc';
                push @found, File::Spec->abs2rel( $File::Find::name, $plugin_root );
            },
        },
        $template_root
    );

    return @found;
}

sub extract_sub {
    my ( $source, $name ) = @_;

    my ($body) = $source =~ m{(sub\s+\Q$name\E\s*\{[\s\S]+?)(?=\nsub\s|\n=head|\z)};
    return $body || q{};
}

my $plugin_pm = read_file('Koha/Plugin/Fi/KohaSuomi/Editx.pm');

for my $template_path (qw(
    Koha/Plugin/Fi/KohaSuomi/Editx/configure.tt
    Koha/Plugin/Fi/KohaSuomi/Editx/tool.tt
)) {
    my @missing = post_form_lines_missing_csrf( read_file($template_path) );
    is_deeply( \@missing, [], "$template_path: every POST form includes the Koha CSRF field" );
}

is_deeply( [ plugin_csrf_include_files() ], [], 'Plugin does not shadow Koha core csrf-token.inc' );

like( $plugin_pm, qr{use Koha::Token;}, 'Plugin loads Koha token support' );

my $csrf_helper = extract_sub( $plugin_pm, '_csrf_token_valid' );
like( $csrf_helper, qr{Koha::Token->new->check_csrf}s, 'Plugin validates POST tokens through Koha::Token' );
like(
    $csrf_helper,
    qr{session_id\s*=>\s*scalar\s+\$cgi->cookie\('CGISESSID'\)}s,
    'Plugin validates CSRF tokens against the Koha staff session cookie'
);
like(
    $csrf_helper,
    qr{token\s*=>\s*scalar\s+\$cgi->param\('csrf_token'\)}s,
    'Plugin reads the standard csrf_token form field'
);

for my $sub_name (qw(
    _run_manual_sync_action
    _manual_sync_confirmation
    _manual_stage_check_remote
    _manual_stage_download_selected
    _manual_stage_import_selected
    _handle_productform_mapping_action
)) {
    like(
        extract_sub( $plugin_pm, $sub_name ),
        qr{!\$self->_csrf_token_valid\(\$cgi\)}s,
        "$sub_name rejects invalid Koha CSRF tokens"
    );
}

like(
    $plugin_pm,
    qr{if\s*\(\$is_export_mapping_csv\)\s*\{\s*if\s*\(\s*!\$self->_csrf_token_valid\(\$cgi\)\s*\)}s,
    'ProductForm mapping CSV export rejects invalid Koha CSRF tokens'
);
like(
    $plugin_pm,
    qr{if\s*\(\$is_save\)\s*\{\s*if\s*\(\s*!\$self->_csrf_token_valid\(\$cgi\)\s*\)}s,
    'Configuration save rejects invalid Koha CSRF tokens'
);

my $tool_template = read_file('Koha/Plugin/Fi/KohaSuomi/Editx/tool.tt');
my @literal_ops   = grep { $_ !~ m{\[%} } $tool_template =~ m{name="op"\s+value="([^"]+)"}g;
my @unsafe_ops    = grep { $_ !~ m{\Acud-} } @literal_ops;
is_deeply( \@unsafe_ops, [], 'Literal POST op values in the tool template use Koha cud-* names' );
like(
    $plugin_pm,
    qr{op\s*=>\s*\$action eq 'stage_check_remote' \? 'cud-stage-check-remote' : 'cud-run-sync-now'}s,
    'Controller-generated confirmation POST op values use Koha cud-* names'
);

done_testing();
