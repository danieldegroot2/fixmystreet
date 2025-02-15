package FixMyStreet::PhotoStorage::FileSystem;

use Moose;
use parent 'FixMyStreet::PhotoStorage';

use Path::Tiny 'path';


has upload_dir => (
    is => 'ro',
    lazy => 1,
    default => sub {
        my $cfg = FixMyStreet->config('PHOTO_STORAGE_OPTIONS');
        my $dir = $cfg ? $cfg->{UPLOAD_DIR} : FixMyStreet->config('UPLOAD_DIR');
        return path($dir)->absolute(FixMyStreet->path_to());
    },
);

=head2 init

Creates UPLOAD_DIR and checks it's writeable.

=cut

sub init {
    my $self = shift;
    my $cache_dir = $self->upload_dir;
    $cache_dir->mkpath;
    unless ( -d $cache_dir && -w $cache_dir ) {
        warn "\x1b[31mCan't find/write to photo cache directory '$cache_dir'\x1b[0m\n";
        return;
    }
    return 1;
}

=head2 get_file

Returns a Path::Tiny path to a file on disk identified by an ID and type.
File may or may not exist. This handle is then used to read photo data or
write to disk.

=cut

sub get_file {
    my ($self, $filename) = @_;
    my $cache_dir = $self->upload_dir;
    return path( $cache_dir, $filename );
}


=head2 store_photo

Stores a blob of binary data representing a photo on disk.
Returns a key which is used in the future to get the contents of the file.

=cut

sub store_photo {
    my ($self, $photo_blob) = @_;

    my $type = $self->detect_type($photo_blob) || 'jpeg';
    my $fileid = $self->get_fileid($photo_blob);
    my $file = $self->get_file("$fileid.$type");
    $file->spew_raw($photo_blob);

    return $file->basename;
}


=head2 retrieve_photo

Fetches the file content of a particular photo from storage.
Returns the binary blob, the filetype, and the file path, if
the photo exists in storage.

=cut

sub retrieve_photo {
    my ($self, $filename) = @_;

    my $file = $self->get_file($filename);
    if ($file->exists) {
        my $photo = $file->slurp_raw;
        return ($photo, $file);
    }
}

1;
