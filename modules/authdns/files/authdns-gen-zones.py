#!/usr/bin/env python

import argparse
import sys
import os
import time
import jinja2
from filecmp import dircmp

HEADER = '''; WARNING!
; This file was automatically generated from a template
; Do NOT edit this file directly!

'''


def parse_args():
    """Sets ups argument parser and its arguments, returns args"""
    parser = argparse.ArgumentParser()
    parser.add_argument("templatedir",
                        help="the directory containing the zone templates")
    parser.add_argument("zonedir",
                        help="the directory containing the formatted zones")
    parser.add_argument("zones",
                        help="zones to regenerate (optional, implies -f -k)",
                        nargs="*")
    parser.add_argument("-v", "--verbose",
                        help="increase output verbosity",
                        action="store_true",
                        default=0)
    parser.add_argument("-f", "--force",
                        help="force regeneration of all zones",
                        action="store_true",
                        default=0)
    parser.add_argument("-k", "--keep",
                        help="keep zones for which no templates exist",
                        action="store_true",
                        default=0)

    return parser.parse_args()


def main():
    """main"""
    args = parse_args()

    template_env = jinja2.Environment(
        loader=jinja2.FileSystemLoader(args.templatedir),
        undefined=jinja2.StrictUndefined,
        cache_size=0,
    )

    errors = False
    context = {}
    context['serial'] = time.strftime('%Y%m%d%H', time.gmtime())

    if args.zones:
        zones = args.zones
        args.force = True
        args.keep = True
    else:
        zones = os.listdir(args.templatedir)

    for filename in zones:
        templatepath = os.path.join(args.templatedir, filename)
        zonepath = os.path.join(args.zonedir, filename)
        context['zonename'] = filename

        # only process regular files and symlinks
        if not os.path.isfile(templatepath) or filename.startswith('.'):
            if args.zones:
                print "Skipping non-existent zone", filename
            continue

        try:
            if not args.force and (
                    os.path.getmtime(templatepath) <=
                    os.path.getmtime(zonepath)):
                continue
        except OSError:
            # destination file not found
            pass

        if args.verbose:
            print 'Processing zone', filename

        try:
            template = template_env.get_template(filename)
            output = template.render(context)
        except jinja2.exceptions.TemplateSyntaxError, exc:
            print 'Skipping zone %s, syntax error on line %d: %s' % \
                  (filename, exc.lineno, exc.message)
            errors = True
            continue
        except jinja2.exceptions.TemplateError, exc:
            print 'Skipping zone %s, could not parse: %s' % \
                  (filename, str(exc))
            errors = True
            continue

        # Write zonefile
        open(zonepath, 'w').write(HEADER + output + "\n")

    if not args.keep:
        # cleanup removed zones
        dcmp = dircmp(args.templatedir, args.zonedir)
        for filename in dcmp.right_only:
            if filename.startswith('.'):
                continue
            if args.verbose:
                print "Cleaning up zone", filename
            os.unlink(os.path.join(args.zonedir, filename))

    if errors:
        sys.exit(1)

if __name__ == '__main__':
    main()

# vim: ts=4 sts=4 et ai shiftwidth=4 fileencoding=utf-8
