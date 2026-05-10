#!/usr/bin/perl
package Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::File;

use Modern::Perl;
use Moose;
use Data::Dumper;
use File::Slurp;
use File::Copy;
use File::Basename;
use File::Path qw(make_path);
use File::Spec;
use XML::LibXML;

use C4::Context;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Logger;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EdiMessage;
use Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config;

has 'objectFactory' => (
    is      => 'rw',
    isa => 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EditX::Xml::ObjectFactory'
);

has 'logger' => (
    is      => 'rw',
    isa => 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Logger',
    reader => 'getLogger',
    writer => 'setLogger',
);

has 'edi_msg' => (
    is      => 'rw',
    reader => 'getMsgUpdater',
    writer => 'setMsgUpdater',
);

has 'config' => (
    is      => 'rw',
    isa => 'Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config',
    reader => 'getConfig',
    writer => 'setConfig',
);

has 'tmp_path' => (
    is      => 'rw',
    reader => 'getTmpPath',
    writer => 'setTmpPath',
);

has 'load_path' => (
    is      => 'rw',
    reader => 'getLoadPath',
    writer => 'setLoadPath',
);

has 'archive_path' => (
    is      => 'rw',
    reader => 'getArchivePath',
    writer => 'setArchivePath',
);

has 'fail_path' => (
    is      => 'rw',
    reader => 'getFailPath',
    writer => 'setFailPath',
);

my @filteredFileNames = ( '.', '..' );
my %filteredFileNamesHash;

sub BUILD {
    my $self = shift;
    my ($tmpPath, $loadPath, $archivePath, $failPath);
    $self->setLogger(new Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Logger);
    $self->setConfig(new Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::Config);
    $self->setMsgUpdater(new Koha::Plugin::Fi::KohaSuomi::Editx::Procurement::EdiMessage);
    %filteredFileNamesHash = map { $_ => 1 } @filteredFileNames;

    my $settings = $self->getConfig()->getSettings();
    if(defined $settings->{'settings'}->{'import_tmp_path'}){
        $tmpPath = $settings->{'settings'}->{'import_tmp_path'};
        $tmpPath = $self->normalizePath($tmpPath);
        $self->setTmpPath($tmpPath);
    }
    if(defined $settings->{'settings'}->{'import_load_path'}){
        $loadPath = $settings->{'settings'}->{'import_load_path'};
        $loadPath = $self->normalizePath($loadPath);
        $self->setLoadPath($loadPath);
    }
    if(defined $settings->{'settings'}->{'import_archive_path'}){
        $archivePath = $settings->{'settings'}->{'import_archive_path'};
        $archivePath = $self->normalizePath($archivePath);
        $self->setArchivePath($archivePath);
    }
    if(defined $settings->{'settings'}->{'import_failed_path'}){
        $failPath = $settings->{'settings'}->{'import_failed_path'};
        $failPath = $self->normalizePath($failPath);
        $self->setFailPath($failPath);
    }

    $self->_ensure_import_directory( 'import_tmp_path',     $tmpPath );
    $self->_ensure_import_directory( 'import_load_path',    $loadPath );
    $self->_ensure_import_directory( 'import_archive_path', $archivePath );
    $self->_ensure_import_directory( 'import_failed_path',  $failPath );
}

sub _ensure_import_directory {
    my ( $self, $setting_name, $path ) = @_;

    die("$setting_name not set.") if !defined $path || $path eq '';
    die("$setting_name must be an absolute path: $path") if !File::Spec->file_name_is_absolute($path);

    if ( !-e $path ) {
        eval { make_path($path); 1 } or die "$setting_name could not be created: $@";
    }

    die("$setting_name is not a directory: $path") if !-d $path;
    die("$setting_name is not writable by the Koha process: $path") if !-w $path || !-x $path;

    return 1;
}

sub fileAlreadyImported {
    my $self = shift;
    my $fileName = $_[0];
    my $filePath = $self->getTmpPath() . $fileName;

    return $self->filePathAlreadyImported( $filePath, $fileName );
}

sub filePathAlreadyImported {
    my $self = shift;
    my $filePath = $_[0];

    my $basketName = $self->basketNameFromFile($filePath);
    return $self->basketNameAlreadyImported($basketName);
}

sub archiveFile {
    my $self = shift;
    my $filePath = $_[0];
    my $fileName = $self->getFilenaMeFromPath($filePath);
    my $archivePath = $self->getArchivePath() . $fileName;

    $self->getMsgUpdater()->update($fileName, 'OK');
    $self->_move_file_or_die( $filePath, $archivePath, "File: $filePath moved to $archivePath for archive." );
}

sub getFilenaMeFromPath {
    my $self = shift;
    my $filePath = $_[0];
    my $fileName = fileparse($filePath);
    return $fileName;
}

sub moveToFailFolder{
    my $self = shift;
    my $filePath = $_[0];
    my $fileName = $self->getFilenaMeFromPath($filePath);
    my $failPath = $self->getFailPath() . $fileName;

    $self->getMsgUpdater()->update($fileName, 'FAILED');
    $self->_move_file_or_die( $filePath, $failPath, "File: $filePath moved to $failPath." );
}

sub _move_file_or_die {
    my ( $self, $filePath, $targetPath, $successMessage ) = @_;

    if ( move( $filePath, $targetPath ) ) {
        $self->getLogger()->log($successMessage);
        return 1;
    }

    my $error = $! || 'unknown error';
    my $failMessage = "File: $filePath could not be moved to $targetPath: $error";
    $self->getLogger()->logError($failMessage);
    die $failMessage;
}

sub discardDuplicateFile {
    my $self = shift;
    my $filePath = $_[0];
    my $fileName = $self->getFilenaMeFromPath($filePath);

    $self->getMsgUpdater()->update($fileName, 'DUPLICATE');
    if ( unlink $filePath ) {
        $self->getLogger()->log("File: $filePath already imported. Removing it.");
        return 1;
    }

    my $error = $! || 'unknown error';
    my $failMessage = "File: $filePath already imported but could not be unlinked: $error";
    $self->getLogger()->logError($failMessage);
    die $failMessage;
}

sub fillLoadFolder {
    my $self = shift;
    my $tmpPath = $self->getTmpPath();
    my $loadPath = $self->getLoadPath();
    my @tmpFiles = $self->getFileNamesInDirectory($tmpPath);
    my %result = (
        staged    => 0,
        skipped   => 0,
        postponed => 0,
    );

    my ($tmpFile, $fullPath, $fullLoadPath, $fullMessage);

    if(@tmpFiles > 2){
        foreach(@tmpFiles){
            $tmpFile = $_;
            $fullPath = $tmpPath . $tmpFile;
            $fullLoadPath = $loadPath . $tmpFile;
            if($self->filterFile($tmpFile)){
                next;
            }

            $fullMessage = read_file($fullPath);
            $self->getMsgUpdater()->add($tmpFile, $fullMessage);

            if (eval{XML::LibXML->new()->parse_file($fullPath)}) {
                $self->getMsgUpdater()->findBookseller($fullPath);
            } else {
                $self->getMsgUpdater()->update($tmpFile, 'POSTPONED');
                $self->getLogger()->logError("File: $fullPath is not valid XML, processing postponed.");
                $result{postponed}++;
                next;
            }
            if(!$self->fileAlreadyImported($tmpFile)){
                $self->getMsgUpdater()->update($tmpFile, 'PROCESSING');
                $self->_move_file_or_die( $fullPath, $fullLoadPath, "File: $fullPath moved to $fullLoadPath for import." );
                $result{staged}++;
            }
            else{
                $self->discardDuplicateFile($fullPath);
                $result{skipped}++;
            }
        }
    }
    else{
        $self->getLogger()->log("No new files found in $tmpPath for import.");
    }
    return \%result;
}

sub registerFileForImport {
    my ( $self, $filePath ) = @_;

    my $fileName = $self->getFilenaMeFromPath($filePath);
    my $fullMessage = read_file($filePath);
    $self->getMsgUpdater()->add($fileName, $fullMessage);

    if ( eval { XML::LibXML->new()->parse_file($filePath) } ) {
        $self->getMsgUpdater()->findBookseller($filePath);
        $self->getMsgUpdater()->update($fileName, 'PROCESSING');
        return 1;
    }

    my $error = $@ || 'unknown XML parse error';
    $self->getMsgUpdater()->update($fileName, 'POSTPONED');
    $self->getLogger()->logError("File: $filePath is not valid XML, processing postponed.");
    die "File: $filePath is not valid XML: $error";
}

sub normalizePath {
    my $self = shift;
    my $path = $_[0];
    $path = $1 if($path=~/(.*)\/$/);
    $path = $path . '/';
    return $path;
}

sub getFileNamesInDirectory{
    my $self = shift;
    my $dirPath = $_[0];
    my @fileNames;

    if( -d $dirPath ){
        opendir(my $dh, $dirPath);
        while(readdir $dh) {
            push @fileNames, $_;
        }
        closedir $dh;
    }

    return @fileNames;
}

sub filterFile{
    my $self = shift;
    my $fileName = $_[0];
    my $result = 0;
    my @exts = ('.xml');
    my ($name, $dir, $ext) = fileparse($fileName, @exts);

    if(!$ext || $ext ne '.xml'){
        $result = 1;
    }

    if(exists($filteredFileNamesHash{$fileName})){
        $result = 1;
    }
    
    return $result;
}

sub basketNameFromFile {
    my $self = shift;
    my $filePath = $_[0];

    return '' if !$filePath || !-f $filePath;

    my $doc = eval { XML::LibXML->new( no_network => 1 )->parse_file($filePath) };
    if (!$doc) {
        my $error = $@ || 'unknown XML parse error';
        $self->getLogger()->logError("Could not read ShipNoticeNumber from $filePath: $error");
        return '';
    }

    my $basketName = $doc->findvalue('/LibraryShipNotice/Header/ShipNoticeNumber');
    $basketName =~ s/\A\s+|\s+\z//g if defined $basketName;

    return $basketName || '';
}

sub basketNameAlreadyImported {
    my $self = shift;
    my $basketName = $_[0];

    return 0 if !defined $basketName || $basketName eq '';

    my ($count) = C4::Context->dbh->selectrow_array(
        q{
            SELECT COUNT(*)
            FROM aqbasket
            WHERE basketname = ?
        },
        undef,
        $basketName
    );

    return $count ? 1 : 0;
}

1;
