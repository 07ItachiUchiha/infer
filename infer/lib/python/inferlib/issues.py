# Copyright (c) 2015 - present Facebook, Inc.
# All rights reserved.
#
# This source code is licensed under the BSD style license found in the
# LICENSE file in the root directory of this source tree. An additional grant
# of patent rights can be found in the PATENTS file in the same directory.

from __future__ import absolute_import
from __future__ import division
from __future__ import print_function
from __future__ import unicode_literals

import codecs
import csv
import json
import os
import shutil
import sys
import tempfile
import xml.etree.ElementTree as ET

from . import config, source, utils


# Increase the limit of the CSV parser to sys.maxlimit
csv.field_size_limit(sys.maxsize)

ISSUE_KIND_ERROR = 'ERROR'
ISSUE_KIND_WARNING = 'WARNING'
ISSUE_KIND_INFO = 'INFO'

ISSUE_TYPES = [
    'ASSERTION_FAILURE',
    'BAD_POINTER_COMPARISON',
    # 'CHECKERS_PRINTF_ARGS'
    # TODO (#8030397): revert this once all the checkers are moved to Infer
    'CONTEXT_LEAK',
    'MEMORY_LEAK',
    'RESOURCE_LEAK',
    'RETAIN_CYCLE',
    'STRONG_DELEGATE_WARNING',
    'TAINTED_VALUE_REACHING_SENSITIVE_FUNCTION',
    'IVAR_NOT_NULL_CHECKED',
    'NULL_DEREFERENCE',
    'PARAMETER_NOT_NULL_CHECKED',
    'PREMATURE_NIL_TERMINATION_ARGUMENT',
]

NULL_STYLE_ISSUE_TYPES = [
    'IVAR_NOT_NULL_CHECKED',
    'NULL_DEREFERENCE',
    'PARAMETER_NOT_NULL_CHECKED',
    'PREMATURE_NIL_TERMINATION_ARGUMENT',
]

# indices in rows of csv reports
CSV_INDEX_CLASS = 0
CSV_INDEX_KIND = 1
CSV_INDEX_TYPE = 2
CSV_INDEX_QUALIFIER = 3
CSV_INDEX_SEVERITY = 4
CSV_INDEX_LINE = 5
CSV_INDEX_PROCEDURE = 6
CSV_INDEX_PROCEDURE_ID = 7
CSV_INDEX_FILENAME = 8
CSV_INDEX_TRACE = 9
CSV_INDEX_KEY = 10
CSV_INDEX_QUALIFIER_TAGS = 11
CSV_INDEX_HASH = 12
CSV_INDEX_BUG_ID = 13
CSV_INDEX_ALWAYS_REPORT = 14
CSV_INDEX_ADVICE = 15

# field names in rows of json reports
JSON_INDEX_FILENAME = 'file'
JSON_INDEX_HASH = 'hash'
JSON_INDEX_KIND = 'kind'
JSON_INDEX_LINE = 'line'
JSON_INDEX_PROCEDURE = 'procedure'
JSON_INDEX_QUALIFIER = 'qualifier'
JSON_INDEX_QUALIFIER_TAGS = 'qualifier_tags'
JSON_INDEX_SEVERITY = 'file'
JSON_INDEX_TYPE = 'bug_type'
JSON_INDEX_TRACE = 'bug_trace'
JSON_INDEX_TRACE_LEVEL = 'level'
JSON_INDEX_TRACE_FILENAME = 'filename'
JSON_INDEX_TRACE_LINE = 'line_number'
JSON_INDEX_TRACE_DESCRIPTION = 'description'
JSON_INDEX_TRACE_NODE_TAGS = 'node_tags'
JSON_INDEX_TRACE_NODE_TAGS_TAG = 'tags'
JSON_INDEX_TRACE_NODE_TAGS_VALUE = 'value'

QUALIFIER_TAGS = 'qualifier_tags'
BUCKET_TAGS = 'bucket'


def clean_csv(args, csv_report):
    collected_rows = []
    with open(csv_report, 'r') as file_in:
        reader = csv.reader(file_in)
        rows = [row for row in reader]
        if len(rows) <= 1:
            return rows
        else:
            for row in rows[1:]:
                filename = row[CSV_INDEX_FILENAME]
                if os.path.isfile(filename):
                    if args.no_filtering \
                       or _should_report_csv(args.analyzer, row):
                        collected_rows.append(row)
            collected_rows = sorted(
                collected_rows,
                cmp=_compare_csv_rows)
            collected_rows = [rows[0]] + collected_rows
    temporary_file = tempfile.mktemp()
    with open(temporary_file, 'w') as file_out:
        writer = csv.writer(file_out)
        writer.writerows(collected_rows)
        file_out.flush()
        shutil.move(temporary_file, csv_report)


def clean_json(args, json_report):
    collected_rows = []
    with open(json_report, 'r') as file_in:
        rows = json.load(file_in)
        for row in rows:
            filename = row[JSON_INDEX_FILENAME]
            if os.path.isfile(filename):
                if args.no_filtering \
                   or _should_report_json(args.analyzer, row):
                    collected_rows.append(row)
        collected_rows = sorted(
            collected_rows,
            cmp=_compare_json_rows)
    temporary_file = tempfile.mktemp()
    with open(temporary_file, 'w') as file_out:
        json.dump(collected_rows, file_out, indent=2)
        file_out.flush()
        shutil.move(temporary_file, json_report)


def print_and_save_errors(json_report, bugs_out):
    errors = []
    with codecs.open(json_report, 'r', encoding=config.LOCALE) as file_in:
        errors = filter(lambda row: row[JSON_INDEX_KIND] in
                        [ISSUE_KIND_ERROR, ISSUE_KIND_WARNING],
                        json.load(file_in))

    text_errors_list = []
    for row in errors:
        filename = row[JSON_INDEX_FILENAME]
        if not os.path.isfile(filename):
            continue

        kind = row[JSON_INDEX_KIND]
        line = row[JSON_INDEX_LINE]
        error_type = row[JSON_INDEX_TYPE]
        msg = row[JSON_INDEX_QUALIFIER]
        source_context = source.build_source_context(filename,
                                                     source.TERMINAL_FORMATTER,
                                                     int(line))
        indenter = source.Indenter() \
                         .indent_push() \
                         .add(source_context)
        source_context = unicode(indenter)
        text_errors_list.append(u'%s:%d: %s: %s\n  %s\n%s' % (
            filename,
            line,
            kind.lower(),
            error_type,
            msg,
            source_context,
        ))

    n_issues = len(text_errors_list)
    with codecs.open(bugs_out, 'w', encoding=config.LOCALE) as file_out:
        if n_issues == 0:
            _print_and_write(file_out, 'No issues found')
        else:
            msg = '\nFound %s\n' % utils.get_plural('issue', n_issues)
            _print_and_write(file_out, msg)
            text_errors = '\n\n'.join(text_errors_list)
            _print_and_write(file_out, text_errors)


def _compare_issues(filename_1, line_1, filename_2, line_2):
    if filename_1 < filename_2:
        return -1
    elif filename_1 > filename_2:
        return 1
    else:
        return line_1 - line_2


def _compare_csv_rows(row_1, row_2):
    filename_1 = row_1[CSV_INDEX_FILENAME]
    filename_2 = row_2[CSV_INDEX_FILENAME]
    line_1 = int(row_1[CSV_INDEX_LINE])
    line_2 = int(row_2[CSV_INDEX_LINE])
    return _compare_issues(filename_1, line_1, filename_2, line_2)


def _compare_json_rows(row_1, row_2):
    filename_1 = row_1[JSON_INDEX_FILENAME]
    filename_2 = row_2[JSON_INDEX_FILENAME]
    line_1 = row_1[JSON_INDEX_LINE]
    line_2 = row_2[JSON_INDEX_LINE]
    return _compare_issues(filename_1, line_1, filename_2, line_2)


def _should_report(analyzer, error_kind, error_type, error_bucket):
    analyzers_whitelist = [
        config.ANALYZER_ERADICATE,
        config.ANALYZER_CHECKERS,
        config.ANALYZER_TRACING,
    ]
    error_kinds = [ISSUE_KIND_ERROR, ISSUE_KIND_WARNING]
    null_style_buckets = ['B1', 'B2']

    if analyzer in analyzers_whitelist:
        return True

    if error_kind not in error_kinds:
        return False

    if not error_type:
        return False

    if error_type in NULL_STYLE_ISSUE_TYPES:
        return error_bucket in null_style_buckets

    return error_type in ISSUE_TYPES


def _should_report_csv(analyzer, row):
    error_kind = row[CSV_INDEX_KIND]
    error_type = row[CSV_INDEX_TYPE]
    error_bucket = ''  # can be updated later once we extract it from qualifier

    try:
        qualifier_xml = ET.fromstring(row[CSV_INDEX_QUALIFIER_TAGS])
        if qualifier_xml.tag == QUALIFIER_TAGS:
            bucket = qualifier_xml.find(BUCKET_TAGS)
            if bucket is not None:
                error_bucket = bucket.text
    except ET.ParseError:
        pass  # this will skip any invalid xmls

    return _should_report(analyzer, error_kind, error_type, error_bucket)


def _should_report_json(analyzer, row):
    error_kind = row[JSON_INDEX_KIND]
    error_type = row[JSON_INDEX_TYPE]
    error_bucket = ''  # can be updated later once we extract it from qualifier

    for qual_tag in row[QUALIFIER_TAGS]:
        if qual_tag['tag'] == BUCKET_TAGS:
            error_bucket = qual_tag['value']
            break

    return _should_report(analyzer, error_kind, error_type, error_bucket)


def _print_and_write(file_out, message):
    print(message)
    file_out.write(message + '\n')
