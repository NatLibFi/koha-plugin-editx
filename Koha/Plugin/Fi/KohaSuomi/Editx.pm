package Koha::Plugin::Fi::KohaSuomi::Editx;
## It's good practice to use Modern::Perl
use Modern::Perl;
## Required for all plugins
use base qw(Koha::Plugins::Base);
## We will also need to include any Koha libraries we want to access
use C4::Context;
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
    maximum_version => '',
    version         => $VERSION,
    description     => 'Adds EDItX functionality to Koha',
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


    my $success = 1;

    # my $table_sequences = $self->get_qualified_table_name('sequences');
        # CREATE TABLE IF NOT EXISTS `$table_sequences` (
    $success &&= C4::Context->dbh->do( "
        CREATE TABLE IF NOT EXISTS `editx_sequences` (
          `invoicenumber` int(11) NOT NULL,
          `item_barcode_nextval` int(11) NOT NULL
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    " );

    # my $table_map_productform = $self->get_qualified_table_name('map_productform');
        # CREATE TABLE `$table_map_productform` (
    $success &&= C4::Context->dbh->do( "
        CREATE TABLE IF NOT EXISTS `editx_map_productform` (
          `onix_code` varchar(10) NOT NULL,
          `productform` varchar(10) NOT NULL,
          `productform_alternative` varchar(10) NOT NULL,
          PRIMARY KEY (`onix_code`),
          KEY `fk_productform_itemtypes` (`productform`),
          KEY `fk_productformalt_itemtypes` (`productform_alternative`),
          CONSTRAINT `fk_productform_itemtypes` FOREIGN KEY (`productform`) REFERENCES `itemtypes` (`itemtype`),
          CONSTRAINT `fk_productformalt_itemtypes` FOREIGN KEY (`productform_alternative`) REFERENCES `itemtypes` (`itemtype`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    " );

    return $success;
}

## This is the 'upgrade' method. It will be triggered when a newer version of a
## plugin is installed over an existing older version of a plugin
sub upgrade {
    my ( $self, $args ) = @_;

    my $dt = dt_from_string();
    $self->store_data( { last_upgraded => $dt->ymd('-') . ' ' . $dt->hms(':') } );

    my $success = 1;

    if ( !C4::Context->dbh->do("SHOW TABLES LIKE 'sequences'") ) {
        # rename table 'sequences' to 'editx_sequences'
        $success &&= C4::Context->dbh->do("RENAME TABLE `sequences` TO `editx_sequences`");
    }

    if ( !C4::Context->dbh->do("SHOW TABLES LIKE 'map_productform'") ) {
        # rename table 'map_productform' to 'editx_map_productform'
        $success &&= C4::Context->dbh->do("RENAME TABLE `map_productform` TO `editx_map_productform`");
    }

    return $success;
}
## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
sub uninstall() {
    my ( $self, $args ) = @_;

    # my $table_sequences = $self->get_qualified_table_name('sequences');
    # my $table_map_productform = $self->get_qualified_table_name('map_productform');
        # DROP TABLE IF EXISTS `$table_sequences` (

    my $success = 1;

    $success &&= C4::Context->dbh->do("DROP TABLE IF EXISTS `editx_sequences`");
    $success &&= C4::Context->dbh->do("DROP TABLE IF EXISTS `editx_map_productform`");

    return $success;
}

1;
