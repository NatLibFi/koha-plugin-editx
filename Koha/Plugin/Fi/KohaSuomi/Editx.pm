package Koha::Plugin::Fi::KohaSuomi::Editx;
## It's good practice to use Modern::Perl
use Modern::Perl;
## Required for all plugins
use base qw(Koha::Plugins::Base);
## We will also need to include any Koha libraries we want to access
use C4::Context;
use Koha::DateUtils qw(dt_from_string);
use Text::CSV_XS;
use utf8;
## Here we set our plugin version
our $VERSION = "{VERSION}";
## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'EDItX-plugin',
    author          => 'Lari Strand',
    date_authored   => '2022-04-05',
    date_updated    => '1900-01-01',
    minimum_version => '23.11',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'Adds EDItX functionality to Koha. (Paikalliskannat)',
};
## This is the minimum code required for a plugin's 'new' method
## More can be added, but none should be removed
sub new {
    my ( $class, $args ) = @_;
    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;
    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual 
    my $self = $class->SUPER::new($args);
    return $self;
}
## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
sub install() {
    my ( $self, $args ) = @_;

    return $self->_install_or_upgrade_tables();
}

sub _install_or_upgrade_tables {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $sequences_table = $self->_quote_identifier( $self->get_qualified_table_name('sequences') );
    my $map_productform_table = $self->_quote_identifier( $self->get_qualified_table_name('map_productform') );

    my $success = $dbh->do( "
        CREATE TABLE IF NOT EXISTS $sequences_table (
          `invoicenumber` int(11) NOT NULL,
          `item_barcode_nextval` int(11) NOT NULL
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    " );

    warn "Failed to create sequences table: " . $dbh->errstr unless $success;

    $success &&= $dbh->do( "
        CREATE TABLE IF NOT EXISTS $map_productform_table (
          `onix_code` varchar(10) NOT NULL,
          `productform` varchar(10) DEFAULT NULL,
          `productform_alternative` varchar(10) DEFAULT NULL,
          PRIMARY KEY (`onix_code`),
          KEY `fk_productform_itemtypes` (`productform`),
          KEY `fk_productformalt_itemtypes` (`productform_alternative`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    " );

    warn "Failed to create map_productform table: " . $dbh->errstr unless $success;

    $success &&= $self->_drop_map_productform_foreign_keys();
    $success &&= $self->_allow_nullable_map_productform_columns();
    $success &&= $self->_migrate_legacy_sequences_table();
    $success &&= $self->_migrate_legacy_map_productform_table();
    $success &&= $self->_ensure_sequences_row();

    return $success;
}

## This is the 'upgrade' method. It will be triggered when a newer version of a
## plugin is installed over an existing older version of a plugin
sub upgrade {
    my ( $self, $args ) = @_;

    my $dt = dt_from_string();
    $self->store_data( { last_upgraded => $dt->ymd('-') . ' ' . $dt->hms(':') } );

    return $self->_install_or_upgrade_tables();
}
## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
sub uninstall() {
    my ( $self, $args ) = @_;

    my $success = 1;
    my $sequences_table = $self->_quote_identifier( $self->get_qualified_table_name('sequences') );
    my $map_productform_table = $self->_quote_identifier( $self->get_qualified_table_name('map_productform') );

    $success &&= C4::Context->dbh->do("DROP TABLE IF EXISTS $sequences_table");
    $success &&= C4::Context->dbh->do("DROP TABLE IF EXISTS $map_productform_table");

    return $success;
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    my @messages;
    my $saved;
    my $nightly_sync_enabled =
          $cgi->request_method eq 'POST'
        ? ( $cgi->param('nightly_sync_enabled') ? 1 : 0 )
        : $self->_nightly_sync_enabled();

    $self->_install_or_upgrade_tables();

    if ( $cgi->request_method eq 'POST' && $cgi->param('save') ) {
        my $mapping_csv = $cgi->param('mapping_csv') // '';
        my ( $rows, $parse_messages, $has_blocking_errors ) = $self->_parse_productform_mapping_csv($mapping_csv);
        push @messages, @$parse_messages;

        if ($has_blocking_errors) {
            $self->_output_configure_page(
                mapping_csv            => $mapping_csv,
                messages               => \@messages,
                nightly_sync_enabled   => $nightly_sync_enabled,
                saved                  => 0,
            );
            return;
        }

        my $save_messages = $self->_save_productform_mappings($rows);
        push @messages, @$save_messages;
        if (@$save_messages) {
            $self->_output_configure_page(
                mapping_csv            => $mapping_csv,
                messages               => \@messages,
                nightly_sync_enabled   => $nightly_sync_enabled,
                saved                  => 0,
            );
            return;
        }
        $self->store_data(
            {
                nightly_sync_enabled => $nightly_sync_enabled,
                last_configured_by   => ( C4::Context->userenv || {} )->{'number'},
            }
        );
        $saved = 1;
    }

    $self->_output_configure_page(
        mapping_csv            => $self->_productform_mapping_csv(),
        messages               => \@messages,
        nightly_sync_enabled   => $nightly_sync_enabled,
        saved                  => $saved,
    );
}

sub cronjob_nightly {
    my ($self) = @_;

    unless ( $self->_nightly_sync_enabled() ) {
        print "EDItX nightly synchronization is disabled in plugin configuration.\n";
        return 1;
    }

    return $self->_run_nightly_sync();
}

sub _migrate_legacy_sequences_table {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $target = $self->get_qualified_table_name('sequences');
    my $quoted_target = $self->_quote_identifier($target);

    for my $source ( 'editx_sequences', 'sequences' ) {
        next if $source eq $target;
        next unless $self->_table_exists($source);

        my $quoted_source = $self->_quote_identifier($source);
        my ($target_count) = $dbh->selectrow_array("SELECT COUNT(*) FROM $quoted_target");
        next if $target_count;

        $dbh->do( "
            INSERT INTO $quoted_target (invoicenumber, item_barcode_nextval)
            SELECT invoicenumber, item_barcode_nextval FROM $quoted_source LIMIT 1
        " ) or return;
    }

    return 1;
}

sub _migrate_legacy_map_productform_table {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $target = $self->get_qualified_table_name('map_productform');
    my $quoted_target = $self->_quote_identifier($target);
    my ($target_count) = $dbh->selectrow_array("SELECT COUNT(*) FROM $quoted_target");

    return 1 if $target_count;

    for my $source ( 'editx_map_productform', 'map_productform' ) {
        next if $source eq $target;
        next unless $self->_table_exists($source);

        my $quoted_source = $self->_quote_identifier($source);
        $dbh->do( "
            INSERT INTO $quoted_target (onix_code, productform, productform_alternative)
            SELECT onix_code, productform, productform_alternative FROM $quoted_source
            ON DUPLICATE KEY UPDATE
                productform = VALUES(productform),
                productform_alternative = VALUES(productform_alternative)
        " ) or return;

        return 1;
    }

    return 1;
}

sub _drop_map_productform_foreign_keys {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $table_name = $self->get_qualified_table_name('map_productform');
    my $quoted_table_name = $self->_quote_identifier($table_name);
    my $sth = $dbh->prepare( "
        SELECT CONSTRAINT_NAME
        FROM information_schema.KEY_COLUMN_USAGE
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = ?
          AND REFERENCED_TABLE_NAME IS NOT NULL
    " );
    $sth->execute($table_name);

    while ( my ($constraint_name) = $sth->fetchrow_array ) {
        my $quoted_constraint_name = $self->_quote_identifier($constraint_name);
        $dbh->do("ALTER TABLE $quoted_table_name DROP FOREIGN KEY $quoted_constraint_name") or return;
    }

    return 1;
}

sub _allow_nullable_map_productform_columns {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $map_productform_table = $self->_quote_identifier( $self->get_qualified_table_name('map_productform') );

    return $dbh->do( "
        ALTER TABLE $map_productform_table
          MODIFY `productform` varchar(10) DEFAULT NULL,
          MODIFY `productform_alternative` varchar(10) DEFAULT NULL
    " );
}

sub _ensure_sequences_row {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $sequences_table = $self->_quote_identifier( $self->get_qualified_table_name('sequences') );
    my ($count) = $dbh->selectrow_array("SELECT COUNT(*) FROM $sequences_table");

    return 1 if $count;

    return $dbh->do("INSERT INTO $sequences_table (invoicenumber, item_barcode_nextval) VALUES (0, 0)");
}

sub _output_configure_page {
    my ( $self, %params ) = @_;

    my $template = $self->get_template( { file => 'configure.tt' } );
    $template->param(
        mapping_csv            => $params{mapping_csv},
        messages               => $params{messages},
        nightly_sync_enabled   => $params{nightly_sync_enabled},
        saved                  => $params{saved},
        itemtypes_text         => join( ', ', @{ $self->_itemtypes() } ),
        last_configured_by     => $self->retrieve_data('last_configured_by'),
        last_upgraded          => $self->retrieve_data('last_upgraded'),
    );

    return $self->output_html( $template->output() );
}

sub _run_nightly_sync {
    my ($self) = @_;

    my $koha_instance = $ENV{KOHA_INSTANCE} || $self->_koha_instance();
    die "KOHA_INSTANCE is not set and could not be detected from KOHA_CONF." unless $koha_instance;

    local $ENV{KOHA_INSTANCE} = $koha_instance;

    my $plugin_path = $self->bundle_path();
    my $fetch_script = "$plugin_path/cronjobs/fetch_editx_sftp.sh";
    my $import_script = "$plugin_path/cronjobs/runEditXImport.pl";
    my $lock_instance = $koha_instance;
    $lock_instance =~ s/[^A-Za-z0-9_.-]/_/g;
    my $lock_dir = "/tmp/editx-nightly-$lock_instance.lock";

    die "No executable EDItX SFTP fetch script: $fetch_script" unless -x $fetch_script;
    die "No EDItX import script: $import_script" unless -f $import_script;

    if ( !mkdir $lock_dir ) {
        print "Another EDItX nightly synchronization is already active for $koha_instance.\n";
        return 1;
    }

    my $success = eval {
        print "Starting EDItX nightly synchronization for $koha_instance.\n";
        $self->_run_command($fetch_script);
        $self->_run_command( $^X, $import_script );
        print "Finished EDItX nightly synchronization for $koha_instance.\n";
        1;
    };
    my $error = $@;

    rmdir $lock_dir or warn "Could not remove EDItX nightly lock $lock_dir: $!";
    die $error unless $success;

    return 1;
}

sub _run_command {
    my ( $self, @command ) = @_;

    system @command;

    my $command_text = join ' ', @command;
    die "Failed to execute $command_text: $!" if $? == -1;
    die "$command_text died with signal " . ( $? & 127 ) if $? & 127;
    die "$command_text exited with status " . ( $? >> 8 ) if $? != 0;

    return 1;
}

sub _koha_instance {
    my ($self) = @_;

    return $ENV{KOHA_INSTANCE} if $ENV{KOHA_INSTANCE};
    return $1 if ( $ENV{KOHA_CONF} // '' ) =~ m{/etc/koha/sites/([^/]+)/koha-conf\.xml\z};
    return;
}

sub _nightly_sync_enabled {
    my ($self) = @_;

    return $self->retrieve_data('nightly_sync_enabled') ? 1 : 0;
}

sub _parse_productform_mapping_csv {
    my ( $self, $mapping_csv ) = @_;

    my $csv = Text::CSV_XS->new(
        {
            binary           => 1,
            allow_whitespace => 1,
            blank_is_undef   => 1,
        }
    );
    my %itemtypes = map { $_ => 1 } @{ $self->_itemtypes() };
    my ( @rows, @messages, %seen_onix_codes );
    my $has_blocking_errors;
    my $line_number = 0;

    open my $fh, '<', \$mapping_csv or die "Cannot read product form mapping CSV: $!";

    while ( my $fields = $csv->getline($fh) ) {
        $line_number++;
        next unless grep { defined $_ && $_ ne '' } @$fields;
        next if $line_number == 1 && $self->_is_productform_mapping_csv_header($fields);

        if ( @$fields != 3 ) {
            push @messages, $self->_configure_message( error => "Line $line_number has " . scalar(@$fields) . " columns; expected 3." );
            $has_blocking_errors = 1;
            next;
        }

        my ( $onix_code, $productform, $productform_alternative ) = map { $self->_trim_csv_value($_) } @$fields;

        unless ($onix_code) {
            push @messages, $self->_configure_message( error => "Line $line_number has no ONIX code." );
            $has_blocking_errors = 1;
            next;
        }

        if ( $seen_onix_codes{$onix_code}++ ) {
            push @messages, $self->_configure_message( warning => "Line $line_number repeats ONIX code '$onix_code'; the later value will win." );
        }

        if ( $productform && !$itemtypes{$productform} ) {
            push @messages, $self->_configure_message( warning => "Line $line_number: item type '$productform' does not exist; productform was stored as NULL." );
            $productform = undef;
        }

        if ( $productform_alternative && !$itemtypes{$productform_alternative} ) {
            push @messages, $self->_configure_message( warning => "Line $line_number: item type '$productform_alternative' does not exist; productform_alternative was stored as NULL." );
            $productform_alternative = undef;
        }

        push @rows,
            {
                onix_code               => $onix_code,
                productform             => $productform,
                productform_alternative => $productform_alternative,
            };
    }

    if ( !$csv->eof ) {
        my ( $code, $message, $position ) = $csv->error_diag();
        push @messages, $self->_configure_message( error => "CSV parse failed at line $line_number, position $position: $message ($code)." );
        $has_blocking_errors = 1;
    }

    close $fh;

    unless (@rows) {
        push @messages, $self->_configure_message( error => 'No product form mappings found in CSV.' );
        $has_blocking_errors = 1;
    }

    return ( \@rows, \@messages, $has_blocking_errors );
}

sub _save_productform_mappings {
    my ( $self, $rows ) = @_;

    my $dbh = C4::Context->dbh;
    my $map_productform_table = $self->_quote_identifier( $self->get_qualified_table_name('map_productform') );
    my @messages;

    my $saved = eval {
        $dbh->begin_work;
        $dbh->do("DELETE FROM $map_productform_table") or die $dbh->errstr;

        my $sth = $dbh->prepare( "
            INSERT INTO $map_productform_table (onix_code, productform, productform_alternative)
            VALUES (?, ?, ?)
            ON DUPLICATE KEY UPDATE
                productform = VALUES(productform),
                productform_alternative = VALUES(productform_alternative)
        " );

        for my $row (@$rows) {
            $sth->execute( $row->{onix_code}, $row->{productform}, $row->{productform_alternative} ) or die $dbh->errstr;
        }

        $dbh->commit;
        1;
    };

    if ( !$saved ) {
        my $error = $@ || $dbh->errstr;
        eval { $dbh->rollback };
        push @messages, $self->_configure_message( error => "Could not save product form mappings: $error" );
    }

    return \@messages;
}

sub _productform_mapping_csv {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $map_productform_table = $self->_quote_identifier( $self->get_qualified_table_name('map_productform') );
    my $sth = $dbh->prepare( "
        SELECT onix_code, productform, productform_alternative
        FROM $map_productform_table
        ORDER BY onix_code
    " );
    $sth->execute();

    my $csv = Text::CSV_XS->new(
        {
            binary => 1,
            eol    => "\n",
        }
    );
    my $mapping_csv = '';

    open my $fh, '>', \$mapping_csv or die "Cannot write product form mapping CSV: $!";
    $csv->print( $fh, [qw(onix_code productform productform_alternative)] );

    while ( my $row = $sth->fetchrow_hashref ) {
        $csv->print(
            $fh,
            [
                $row->{onix_code}               // '',
                $row->{productform}             // '',
                $row->{productform_alternative} // '',
            ]
        );
    }

    close $fh;

    return $mapping_csv;
}

sub _itemtypes {
    my ($self) = @_;

    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare('SELECT itemtype FROM itemtypes ORDER BY itemtype');
    $sth->execute();

    my @itemtypes;
    while ( my ($itemtype) = $sth->fetchrow_array ) {
        push @itemtypes, $itemtype;
    }

    return \@itemtypes;
}

sub _is_productform_mapping_csv_header {
    my ( $self, $fields ) = @_;

    return unless @$fields == 3;

    my @header = map { lc( $self->_trim_csv_value($_) // '' ) } @$fields;
    return $header[0] eq 'onix_code'
        && $header[1] eq 'productform'
        && $header[2] eq 'productform_alternative';
}

sub _trim_csv_value {
    my ( $self, $value ) = @_;

    return unless defined $value;

    $value =~ s/\A\x{FEFF}//;
    $value =~ s/\A\s+|\s+\z//g;
    return $value eq '' || uc($value) eq 'NULL' ? undef : $value;
}

sub _configure_message {
    my ( $self, $type, $text ) = @_;

    return {
        type        => $type,
        alert_class => $type eq 'error' ? 'danger' : $type,
        text        => $text,
    };
}

sub _table_exists {
    my ( $self, $table_name ) = @_;

    my $sth = C4::Context->dbh->prepare("SHOW TABLES LIKE ?");
    $sth->execute($table_name);

    return $sth->fetchrow_array ? 1 : 0;
}

sub _quote_identifier {
    my ( $self, $identifier ) = @_;

    $identifier =~ s/`/``/g;
    return "`$identifier`";
}

1;
